package Fastpass::IO;
use strict;
use warnings;
use Net::FastCGI::IO qw(write_stream);

sub new {
    my($class, $socket, $type, $request_id, $buf_size) = @_;
    bless {
        socket     => $socket,
        type       => $type,
        request_id => $request_id,
        buf_size   => $buf_size,
        buffer     => '',
    }, $class;
}

sub print {
    my($self, $output) = @_;

    $self->{buffer} .= $output;
    if (length $self->{buffer} >= $self->{buf_size}) {
        write_stream($self->{socket}, $self->{type}, $self->{request_id}, $self->{buffer}, 0);
        $self->{buffer} = '';
    }
}

sub flush {
    my $self = shift;
    write_stream($self->{socket}, $self->{type}, $self->{request_id}, $self->{buffer}, 1);
}


1;
