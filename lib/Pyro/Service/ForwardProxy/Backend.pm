package Pyro::Service::ForwardProxy::Backend;
use Any::Moose;
use AnyEvent::HTTP qw(http_request);
use namespace::clean -except => qw(meta);

has host => (
    is => 'ro',
    isa => 'Str',
    required => 1
);

has port => (
    is => 'ro',
    isa => 'Int',
    required => 1
);

has queue => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef',
    lazy_build => 1,
    handles => {
        push_queue => 'push',
        pop_queue  => 'pop',
        is_queue_empty => 'is_empty',
    }
);

my %INSTANCES;

sub _build_queue { [] }

sub host_port { 
    my $self = shift;
    return join(':', $self->host, $self->port);
}

# one connection per host:port, you can push requests
sub instance {
    my ($class, $host, $port) = @_;
    # XXX FIXME - make it more efficient 

    return $INSTANCES{ "$host:$port" } ||= $class->new( host => $host, port => $port );
}

# before pushing a request, make sure it's kosher.
before push_queue => sub {
    # XXX - TODO
};

# once you push a request, start draining
after push_queue => sub {
    my $self = shift;
    $self->drain_queue();
};

sub drain_queue {
    my $self = shift;

    if ($self->is_queue_empty) {
        # if we got here, there was no request. We should stay idle for
        # a certain amount of time, and then remove ourselves from memory

        return;
    }

    if (my $request = $self->pop_queue) {
        return $self->process_request($request);
    }
}

sub process_request {
    my ($self, $request) = @_;

    $self->modify_request( $request );
    $self->send_request( $request );
}

sub send_request {
    my ($self, $request) = @_;

    # basic strategy: 
    #   maybe_cached = has IMS or Etag header
    #   if ( maybe_cached ) {
    #      make a HEAD request with same parameters.
    #      if cache condition matches, and there's a cache,
    #      return the cache 
    #   }
    #
    #   got here, so we have to make a fresh request nonetheless
    #   do a regular request

    # check if we have a IMS header. If we don't have an IMS header,
    # the client thinks it wants a new response, but we might have a
    # cached version somewhere.
    my $ims = $request->header('if-modified-since');

    # this flag is set when there's no chance the request can be cached
    my $no_cache = 
        $request->method !~ /^(?:GET)$/ ||
        ($request->header('Pragma') || '') =~ /\bno-cache\b/ ||
        ($request->header('Cache-Control') || '') =~ /\bno-cache\b/
    ;

    if ($ims || $no_cache) {
        $self->send_request_no_probe( $request );
        return;
    }

    my $guard; $guard = http_request 'HEAD' => $request->original_uri,
        headers => $request->headers,
        on_header => sub {
            undef $guard;
            my $headers = $_[1];
            if ( $headers->{Status} =~ /^30[12]$/) {
                confess "Unimplemented";
            }

            my $respond_on_cache_miss = sub {
                $self->send_request_no_probe( $request );
            };

            if ( $headers->{Status} eq '304' ||
                 $headers->{Status} eq '200'
            ) {
                $request->respond_from_cache( $headers, on_cache_miss => $respond_on_cache_miss);
                return;
            }

            # if we got here, we couldn't cache. do the real transaction
            $self->send_request_no_probe( $request );
        },
    ;
}

sub send_request_no_probe {
    my ($self, $request) = @_;

    $request->log->debug("BACKEND: send request no probe\n");
    $request->log->debug("BACKEND: " .
        $request->method . " " . $request->original_uri . "\n"
    );
    http_request
        $request->method => $request->original_uri,
        headers => $request->headers,
        recurse => 0,

        on_header => sub {
            $request->log->debug( "BACKEND got headers\n" );
            $request->respond_headers( $_[0] );
            return 1;
        },
        on_body => sub {
            $request->log->debug( "BACKEND got body\n" );
            if ($_[0]) {
                $request->respond_data( $_[0] );
            }
            return 1;
        },
        sub {
            $request->log->debug( "BACKEND finalize request\n" );
            $request->finalize_response();
            $self->drain_queue();
        }
    ;
}

sub modify_request {
    my ($self, $request) = @_;

    # Normalize the URI (hey, you DID send us a complete URI, right?)
    # After this point, we /guarantee/ that the request contains a valid Host
    # header, and the request URL doesn't contain anything before the path 
    my $uri = $request->uri;
    if (my $code = $uri->can('host')) {
        if (my $host = $code->($uri)) {
            if ( ! $request->header('Host')) { # XXX is this right?
                my $port = $uri->port;
                $request->header(Host => "$host:$port");
            }

            $uri->scheme(undef);
            $uri->host(undef);
            $uri->port(undef);
            $uri->authority(undef); # XXX need to fix this later
        }
    }
    if (! $uri->path) {
        $uri->path('/');
    }

    $request->_request->remove_header('Connection');
    if (! $request->header('If-Modified-Since') && (my $hcache = $request->hcache) ) {
        # check if we have a Last-Modified stored
        my $last_modified = $hcache->get_last_modified_cache_for( $request );
        if ($last_modified) {
            $request->header('If-Modified-Since',
                HTTP::Date::time2str( $last_modified ) );
        }
    }
}

__PACKAGE__->meta->make_immutable();

1;

__END__

=head1 NAME

Pyro::Service::ForwardProxy::Backend - Handle Backend Connection

=head1 SYNOPSIS

    my $backend = Pyro::Service::ForwardProxy::Backend->instance( $host, $port );
    $backend->push_queue( $request );

=cut
