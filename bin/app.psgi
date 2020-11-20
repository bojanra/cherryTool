#!/usr/bin/perl -w

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

use strict;
use warnings;
use cherryWeb;
use Plack::Builder;

builder {
    enable 'ChRemoteAddr';
    enable 'ServerStatus::Tiny', path => '/internal';
    enable 'Deflater';
    mount '/' => cherryWeb->to_app;
};
