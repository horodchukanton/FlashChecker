#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

our $Bin;
BEGIN {
  use FindBin '$Bin';
  unshift @INC, "$Bin/lib";
}

use FlashChecker;
use Config::Any;

my $config = Config::Any::INI->load($Bin . '/config.ini');

FlashChecker->start($config);

exit 0;