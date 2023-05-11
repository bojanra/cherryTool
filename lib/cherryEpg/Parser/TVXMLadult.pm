package cherryEpg::Parser::TVXMLadult;

use 5.024;
use utf8;
use Moo;

extends 'cherryEpg::Parser::TVXMLdirty';

our $VERSION = '0.11';

=head1

To all events a parental rating descriptor with 18+ is added.

=cut

after 'parse' => sub {
  my $output = shift;
  my $report = $output->{report}->{eventList};

  foreach my $event ( @{$report} ) {
    $event->{parental_rating} = 18;
  }
};

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
