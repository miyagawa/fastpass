package Fastpass;
use strict;
use warnings;

use 5.008_001;
our $VERSION = "0.1000";

use Fastpass::Server;
use Getopt::Long ();

sub new {
    my $class = shift;
    bless {
        options  => {
            workers => 5,
        },
    }, $class;
}

sub parse_options {
    my($self, @args) = @_;

    Getopt::Long::GetOptionsFromArray(
        \@args,
        "listen=s",     \$self->{options}{listen},
        "workers=i",    \$self->{options}{workers},
        "a|app=s",      \$self->{app},
        "h|help",       sub { $self->show_help; exit(0) },
        "v|version",    sub { print "fastpass $VERSION\n"; exit(0) },
    ) or exit(1);

    $self->{app} ||= shift(@args) || "app.psgi";
}

sub show_help {
    my $self = shift;
    print <<HELP;
Usage:
  fastpass --listen /tmp/fcgi.sock myapp.psgi

Run `man fastpass` or `perldoc fastpass` for more options.
HELP
}

sub _load_app {
    my $_file = shift;
    local $ENV{PLACK_ENV} = 'deployment';
    local $0 = $_file;
    local @ARGV = (); # Dancer
    eval 'package Fastpass::App::Sandbox; my $app = do $_file';
}

sub run {
    my $self = shift;

    my $file = $self->{app};
    my $app  = _load_app($file);

    unless (ref $app eq 'CODE') {
        no warnings 'uninitialized';
        die <<DIE;
The application ($app) is not a PSGI application.
The error opening file '$file' was: $!
DIE
    }

    my $server = Fastpass::Server->new(%{$self->{options}});
    $server->run($app);
}

1;
__END__

=encoding utf-8

=for stopwords

=head1 NAME

Fastpass - FastCGI daemon for PSGI apps

=head1 SYNOPSIS

  fastpass --listen :8080 --workers 24 myapp.psgi

=head1 DESCRIPTION

Fastpass is a standalone FastCGI daemon that is designed to work out of
the box with nginx HTTP server. The supported feature set is close to
L<Unicorn|http://unicorn.bogomips.org/> and L<Starman>
i.e. preforking, TCP and UNIX domain socket support and PSGI
compatible, but Fastpass works with the FastCGI protocol instead of HTTP.

=head1 CONFIGURATIONS

TBD

=head1 AUTHOR

Tatsuhiko Miyagawa E<lt>miyagawa@bulknews.netE<gt>

Christian Hansen

=head1 COPYRIGHT

Copyright 2011- Tatsuhiko Miyagawa

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<Plack::Handler::FCGI>, L<FCGI>, L<Net::FastCGI>

=cut
