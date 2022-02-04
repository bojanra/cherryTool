#!/usr/bin/perl -w

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

use strict;
use warnings;
use cherryWeb;
use Plack::Builder;

builder {
    mount '/' => cherryWeb->to_app;
};
