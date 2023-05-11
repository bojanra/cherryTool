package cherryEpg::Parser::TVXML2gz;

use 5.024;
use utf8;
use Gzip::Faster;
use Moo;
use Try::Tiny;

extends 'cherryEpg::Parser::TVXML2';

our $VERSION = '0.12';

=head3 getSource()

 Unzip the source.
 Return referene to array of lines.

=cut

sub getSource {
  my ($self) = @_;

  my $content = try {
    gunzip_file( $self->{source} );
  } catch {
    $self->error(shift);
    return;
  };

  if ($content) {
    my @list = split( /\n/, $content );

    return \@list;
  }
  return;
} ## end sub getSource

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
