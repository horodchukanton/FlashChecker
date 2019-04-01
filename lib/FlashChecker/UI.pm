package FlashChecker::UI;
use strict;
use warnings FATAL => 'all';

use Carp;

sub new {
    my ( $class, %params ) = @_;
    my $self = { %params };
    bless($self, $class);

    $self->init(%params);

    return $self;
}

sub init {
    my ( $self, %params ) = @_;

    my $ui_type = $params{ui} || 'Mojo';
    my $ui_class = "FlashChecker::UI::$ui_type";
    my $ui_file = "FlashChecker/UI/$ui_type.pm";

    eval {
        require $ui_file;
        $ui_class->import();

        $self->{ui} = $ui_class->new(%params);
        1;
    } or do {
        confess "Failed to instantiate $ui_class : $@\n";
    };

    return 1;
}

sub start {
    my ( $self, %params ) = @_;

    $self->{config} = $params{config};

    return $self->{ui}->run({
        queue => $params{queue},
        %params
    });

}

1;