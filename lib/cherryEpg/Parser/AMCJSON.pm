package cherryEpg::Parser::AMCJSON;

use 5.024;
use utf8;
use JSON::XS;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.11';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $content = try {
        local $/;
        open( my $fh, '<:encoding(UTF-8)', $self->{source} ) || return;
        <$fh>;
    };

    if ( !$content ) {
        $self->error("File empty");
        return $report;
    }

    my $data = JSON::XS->new->decode($content);

    if ( !$data ) {
        $self->error("Content not in JSON format");
        return $report;
    }

    foreach my $item ( @{$data} ) {
        my $event;

        if ( $item->{idopont} ) {
            $event->{start} = try {
                localtime->strptime( $item->{idopont}, "%Y-%m-%d %H:%M:%S" )->epoch;
            } catch {
                $self->error("start_time not valid format [$item->{idopont}]");
            };
        } ## end if ( $item->{idopont} )
        $event->{title}    = $item->{cim}         if $item->{cim};
        $event->{subtitle} = $item->{cim_eredeti} if $item->{cim_eredeti};
        $event->{synopsis} = $item->{szoveg}      if $item->{szoveg};
        $event->{synopsis} .= ' ' . $item->{gyartasi_ev} if $item->{gyartasi_ev};

        push( @{ $report->{eventList} }, $event );
    } ## end foreach my $item ( @{$data})

    return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
