package FlashChecker::UI::Mojo::App;
use strict;
use warnings FATAL => 'all';

use Mojolicious::Lite;
# plugin AutoReload => {};

use Cwd qw(abs_path);
use File::Basename qw(dirname);

use Mojo::IOLoop;
use Data::Dumper;

use FlashChecker::UI::Mojo::EventsHandler;

my $handler = FlashChecker::UI::Mojo::EventsHandler->new();
my $cwd = dirname(abs_path($0));

sub run {
    my ( %params ) = @_;

    init();

    $handler->start(%params);

    return app->start(
        'daemon', 'morbo', '-l' => 'http://*:8080',
        'home'                  => $cwd,
        %{$params{UI}->{Mojo} ? $params{UI}->{Mojo} : {}}
    );
}

sub init {
    push(@{app->renderer->paths}, ( dirname(abs_path($0)) . "/templates" ));
    push(@{app->static->paths}, ( dirname(abs_path($0)) . "/static" ));
    define_routes();

    return 1;
}



sub define_routes {
    websocket '/ws' => sub {
        $handler->websocket_message(shift)
    };

    get '/' => sub {
        my $c = shift;
        $c->render(template => 'index');
    };
}


1;