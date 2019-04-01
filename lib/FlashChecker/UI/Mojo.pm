package FlashChecker::UI::Mojo;
use strict;
use warnings FATAL => 'all';

use base 'FlashChecker::UI';

use FlashChecker::UI::Mojo::App;

sub new {
    my ( $class, %params ) = @_;
    my $self = { %params };
    bless $self, $class;
    return $self;
}

sub run {
    my ( $self, $params ) = @_;
    FlashChecker::UI::Mojo::App::run(%$params);
}

1;