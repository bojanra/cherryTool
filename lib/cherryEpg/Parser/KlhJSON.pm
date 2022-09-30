package cherryEpg::Parser::KlhJSON;

use 5.024;
use utf8;
use JSON::XS;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.13';

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

        if ( $item->{start_time} ) {
            $event->{start} = try {
                localtime->strptime( $item->{start_time}, "%Y-%m-%dT%H:%M:%S" )->epoch;
            } catch {
                $self->error("start_time not valid format [$item->{start_time}]");
            };
        } ## end if ( $item->{start_time...})
        if ( $item->{end_time} ) {
            $event->{stop} = try {
                localtime->strptime( $item->{end_time}, "%Y-%m-%dT%H:%M:%S" )->epoch;
            } catch {
                $self->error("end_time not valid format [$item->{end_time}]");
            };
        } ## end if ( $item->{end_time})
        $event->{title}    = $item->{title}     if $item->{title};
        $event->{subtitle} = $item->{sub_title} if $item->{sub_title};
        $event->{synopsis} = $item->{live_desc} if $item->{live_desc};
        $event->{id}       = $1                 if $item->{id_code} =~ m/(\d+)/;

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
