#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use Data::Dumper;

our $Bin;
BEGIN {
    use FindBin '$Bin';
    unshift @INC, "$Bin/../lib";
}

use_ok('USB::Listener');

my $listener = USB::Listener->new();
my $devices = $listener->get_list_of_devices();

print "Initial count of the devices: " . scalar @$devices . "\n";

my $queue = $listener->listen(period => 1);
my $i = 10;
while ($i--){
    sleep 1;
    print Dumper ($queue->dequeue_nb()) if ($queue->pending());
}


done_testing();

