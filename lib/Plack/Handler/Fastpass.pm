package Plack::Handler::Fastpass;
use strict;
use Fastpass::Server;

sub new {
    my $class = shift;
    bless {
        fastpass => Fastpass::Server->new(workers => 5, @_),
    }, $class;
}

sub run {
    my($self, $app) = @_;
    $self->{fastpass}->run($app);
}

1;
