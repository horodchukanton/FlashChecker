package FlashChecker;
use strict;
use warnings FATAL => 'all';

use Carp;
use Data::Dumper;
use USB::Listener;
use FlashChecker::UI;

sub new {
    my ( $class, $config ) = @_;
    my $self = { config => $config };
    bless $self, $class;

    $self->{listener} = USB::Listener->new(debug => 1);

    my $ui_type = $self->{config}->{UI}->{Type};
    $self->{ui} = FlashChecker::UI->new(
        ui           => $ui_type,
        do_not_start => 1,
        UI           => ${config}->{UI},
        Websocket    => ${config}->{Websocket}
    );

    return $self;
}

#@returns USB::Listener
sub listener {
    return shift->{listener};
}

#@returns FlashChecker::UI
sub start {
    my ( $self ) = @_;

    my $events_queue = $self->{listener}->listen(
        period => $self->{config}->{USB}->{Poll} || 5
    );

    my $ui = $self->{ui}->start(
        config => $self->{config},
        queue  => $events_queue
    );

    return $ui;
}





1;