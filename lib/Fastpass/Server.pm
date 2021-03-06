package Fastpass::Server;
use strict;
use warnings;
use base qw(Net::Server::PreForkSimple);
use constant DEBUG => $ENV{PERL_FASTPASS_DEBUG};

use Carp ();
use IO::Socket ();
use Net::FastCGI 0.12;
use Net::FastCGI::Constant qw[:common :type :flag :role :protocol_status];
use Net::FastCGI::IO       qw[:all];
use Net::FastCGI::Protocol qw[:all];

use Fastpass::IO;
use Fastpass::Writer;

our $STDOUT_BUFFER_SIZE = 8192;
our $STDERR_BUFFER_SIZE = 0;

#use warnings FATAL => 'Net::FastCGI::IO';

sub new {
    my($class, %options) = @_;
    bless {
        %options,
        # FIXME
        values => {
            FCGI_MAX_CONNS   => 1,  # maximum number of concurrent transport connections this application will accept
            FCGI_MAX_REQS    => 1,  # maximum number of concurrent requests this application will accept
            FCGI_MPXS_CONNS  => 0,  # this implementation can't multiplex
        },
    }, $class;
}

sub run {
    my($self, $app) = @_;

    my $listen = ref $self->{listen} eq 'ARRAY' ? $self->{listen}->[0] : $self->{listen};

    $self->{app} = $app;

    my($host, $port, $proto);
    if ($listen && $listen =~ /:\d+$/) {
        ($host, $port) = split /:/, $listen, 2;
        $host ||= "*";
        $proto = 'tcp';
    } elsif ($listen) {
        $host  = 'localhost';
        $port  = $listen;
        $proto = 'unix';
    } else {
        Carp::croak("listen port or socket is not defined.");
    }

    $self->SUPER::run(
        port => $port,
        host => $host,
        proto => $proto,
        log_level => DEBUG ? 4 : 2,
        user   => $>,
        group  => $),
        listen => $self->{backlog} || 1024,
        leave_children_open_on_hup => 1,
        max_servers => $self->{workers},
        min_servers => $self->{workers},
        max_spare_servers => $self->{workers} - 1,
        min_spare_servers => $self->{workers} - 1,
    );
}

sub post_accept_hook {
    my $self = shift;

    $self->{client} = {
        current_id => 0,     # id of the request we're processing
        stdin      => undef, # buffer for STDIN
        params     => undef, # buffer for parameters
        done       => 0,     # done with connection?
        keep_conn  => 0,     # more requests on this connection?
    };
}

sub process_request {
    my $self = shift;

    my $socket = $self->{server}{client};
    my $client = $self->{client};

    while (!$client->{done}) {
        my ($type, $request_id, $content) = read_record($socket)
          or last;

        if (DEBUG) {
            warn '< ', dump_record($type, $request_id, $content), "\n";
        }

        if ($request_id == FCGI_NULL_REQUEST_ID) {
            if ($type == FCGI_GET_VALUES) {
                my $query = parse_params($content);
                my %reply = map { $_ => $self->{values}->{$_} }
                            grep { exists $self->{values}->{$_} }
                            keys %$query;
                write_record($socket, FCGI_GET_VALUES_RESULT,
                    FCGI_NULL_REQUEST_ID, build_params(\%reply));
            }
            else {
                write_record($socket, FCGI_UNKNOWN_TYPE,
                    FCGI_NULL_REQUEST_ID, build_unknown_type($type));
            }
        }
        elsif ($request_id != $client->{current_id} && $type != FCGI_BEGIN_REQUEST) {
            # ignore inactive requests (FastCGI Specification 3.3)
        }
        elsif ($type == FCGI_ABORT_REQUEST) {
            $client->{current_id} = 0;
            $client->{stdin}  = undef;
            $client->{params} = '';
        }
        elsif ($type == FCGI_BEGIN_REQUEST) {
            my ($role, $flags) = parse_begin_request_body($content);
            if ($client->{current_id} or $role != FCGI_RESPONDER) {
                my $status = $client->{current_id} ? FCGI_CANT_MPX_CONN : FCGI_UNKNOWN_ROLE;
                write_record($socket, FCGI_END_REQUEST, $request_id,
                    build_end_request_body(0, $status));
            }
            else {
                $client->{current_id} = $request_id;
                $client->{stdin}      = '';
                $client->{keep_conn}  = ($flags & FCGI_KEEP_CONN);
            }
        }
        elsif ($type == FCGI_PARAMS) {
            $client->{params} .= $content;
        }
        elsif ($type == FCGI_STDIN) {
            $client->{stdin} .= $content;

            unless (length $content) {
                open my $in, "<", \$client->{stdin};

                my $out = Fastpass::IO->new($socket, FCGI_STDOUT, $client->{current_id}, $STDOUT_BUFFER_SIZE);
                my $err = Fastpass::IO->new($socket, FCGI_STDERR, $client->{current_id}, $STDERR_BUFFER_SIZE);

                $self->handle_request(parse_params($client->{params}), $in, $out, $err);

                $out->flush;
                $err->flush;

                write_record($socket, FCGI_END_REQUEST, $client->{current_id},
                    build_end_request_body(0, FCGI_REQUEST_COMPLETE));

                # prepare for next request
                $client->{current_id} = 0;
                $client->{stdin}      = undef;
                $client->{params}     = '';

                last unless $client->{keep_conn};
            }
        }
        else {
            warn(qq/Received an unknown record type '$type'/);
        }
    }
}

sub handle_request {
    my($self, $env, $stdin, $stdout, $stderr) = @_;

    $env = {
        %$env,
        'psgi.version'      => [1,1],
        'psgi.url_scheme'   => ($env->{HTTPS}||'off') =~ /^(?:on|1)$/i ? 'https' : 'http',
        'psgi.input'        => $stdin,
        'psgi.errors'       => $stderr,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 1,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 1,
        'psgi.nonblocking'  => 0,
        'psgix.input.buffered' => 1,
        'psgix.harakiri'    => 1,
    };

    delete $env->{HTTP_CONTENT_TYPE};
    delete $env->{HTTP_CONTENT_LENGTH};

    my $res = $self->{app}->($env);

    if (ref $res eq 'ARRAY') {
        $self->_handle_response($res, $stdout);
    } elsif (ref $res eq 'CODE') {
        $res->(sub {
            $self->_handle_response($_[0], $stdout);
        });
    } else {
        die "Bad response $res";
    }

    if ($env->{'psgix.harakiri.commit'}) {
        $self->{client}{keep_conn} = 0;
        $self->{client}{harakiri}  = 1;
    }
}

sub _handle_response {
    my($self, $res, $stdout) = @_;

    my $hdrs;
    $hdrs = "Status: $res->[0]\015\012";

    my $headers = $res->[1];
    while (my ($k, $v) = splice @$headers, 0, 2) {
        $hdrs .= "$k: $v\015\012";
    }
    $hdrs .= "\015\012";

    $stdout->print($hdrs);

    my $body = $res->[2];
    if (defined $body) {
        if (ref $body eq 'ARRAY') {
            for my $line (@$body) {
                $stdout->print($line) if length $line;
            }
        } else {
            local $/ = \65536 unless ref $/;
            while (defined(my $line = $body->getline)) {
                $stdout->print($line) if length $line;
            }
            $body->close;
        }
    } else {
        return Fastpass::Writer->new($stdout);
    }
}

sub post_client_connection_hook {
    my $self = shift;

    if ($self->{client}{harakiri}) {
        warn "Committing harakiri ($$)\n" if DEBUG;
        exit(0);
    }
}


1;

__END__
