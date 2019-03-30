package FlashChecker::UI::Mojo;
use strict;
use warnings FATAL => 'all';

use Mojolicious::Lite;

get '/' => sub {
    my $c = shift;
    $c->render(template => 'index');
};

app->start;

__DATA__

@@ index.html.ep
% layout 'default';
% title 'Welcome';
<h1>Welcome to the Mojolicious real-time web framework!</h1>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body><%= content %></body>
</html>


1;

1;