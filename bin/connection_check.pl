#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

$| = 1;

do {
    print $_;
    sleep 1;
} for (1 ... 5);
# print STDERR "connection_check Error\n";

exit 0;