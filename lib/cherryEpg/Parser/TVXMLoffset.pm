package cherryEpg::Parser::TVXMLoffset;
use 5.010;
use utf8;
use Moo;
use strictures 2;

extends 'cherryEpg::Parser::TVXMLdirty';

our $VERSION = '0.13';

=head1

Use the first parser option as timeshift offset in hours.
Multiple parser options may be separated by commas or "|"

=cut

around 'parse' => sub {
    my ( $orig, $self, $parserOption ) = @_;
    my $offset = 0;

    if ($parserOption) {
        my @option = split( /[\|,]/, $parserOption );
        $offset       = shift(@option);
        $parserOption = join( ',', @option );
        $parserOption = undef if $parserOption eq '';
    } ## end if ($parserOption)

    my $report = $orig->( $self, $parserOption );

    my $eventList = $report->{eventList};

    foreach my $event ( @{$eventList} ) {
        $event->{start} += $offset * 60 * 60;
        $event->{stop}  += $offset * 60 * 60;
    }
    return $report;
};

=head1 AUTHOR

This software is copyright (c) 2019-2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
