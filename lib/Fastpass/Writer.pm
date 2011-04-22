package Fastpass::Writer;
use strict;

sub new {
    my($class, $handle) = @_;
    bless \$handle, $class;
}

sub write {
    ${$_[0]}->print($_[1]);
}

sub close { }

1;
