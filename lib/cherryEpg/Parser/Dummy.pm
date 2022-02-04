package cherryEpg::Parser::Dummy;
use 5.010;
use utf8;
use Moo;
use strictures 2;

extends 'cherryEpg::Parser';

our $VERSION = '0.21';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

sub parse {
    my ( $self, $option ) = @_;

    return $self->{report};
}

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
