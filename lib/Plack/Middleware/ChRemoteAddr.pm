package Plack::Middleware::ChRemoteAddr;
use strict;
use warnings;
use parent qw( Plack::Middleware );

sub call {
    my ( $self, $env ) = @_;

    # modify the address because we are behind a reverse_proxy
    $env->{'REMOTE_ADDR'} = $env->{'HTTP_X_FORWARDED_FOR'};
    my $res = $self->app->($env);
    return $res;
} ## end sub call

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE.txt', which is part of this source code package.

=cut

1;
