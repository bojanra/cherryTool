package cherryEpg::Parser::DisneyXML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

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

    my $handler = DisneyXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package DisneyXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Try::Tiny;

sub new {
    my $this  = shift;
    my $class = ref($this) || $this;
    my $self  = {};

    bless( $self, $class );
    return $self;
} ## end sub new

sub start_document {
    my ($self) = @_;

    # this will be the list of events
    $self->{eventList} = [];

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ( $self, $element ) = @_;

    $self->{report}            = $self->{'_parser'}->{output};
    $self->{report}{eventList} = $self->{eventList};
    $self->{report}{errorList} = $self->{errorList};
    $self->{report}{channel}   = $self->{Service};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} eq 'Report' ) {
        $self->{Service} = $element->{Attributes}{Name};
    } elsif ( $element->{Name} eq 'Detail' ) {

        my $event = {};
        my $date  = $element->{Attributes}{DATES} // '-';
        my $time  = $element->{Attributes}{TIME}  // '-';
        $event->{start} = try {
            localtime->strptime( $date . ' ' . $time, "%d/%m/%Y %H:%M" )->epoch;
        } catch {
            $self->_error("DATE and TIME valid format [$date $time]");
        };

        if ( $element->{Attributes}{LOCAL_SERIES_TITLE} ) {
            $event->{title} = $element->{Attributes}{LOCAL_SERIES_TITLE};
        } elsif ( $element->{Attributes}{Local_Title2} ) {
            $event->{title} = $element->{Attributes}{Local_Title2};
        }

        if ( $element->{Attributes}{LOCAL_EPISODE_TITLE} ) {
            $event->{subtitle} = $element->{Attributes}{LOCAL_EPISODE_TITLE};
        } elsif ( $element->{Attributes}{Original_Title_Episode} ) {
            $event->{subtitle} = $element->{Attributes}{Original_Title_Episode};
        } else {
            $event->{subtitle} = '';
        }

        my $season;
        if ( $element->{Attributes}{SEASON} ) {
            $season = $element->{Attributes}{SEASON};
        } elsif ( $element->{Attributes}{Season2} ) {
            $season = $element->{Attributes}{Season2};
        }

        my $episode;
        if ( $element->{Attributes}{EPISODE_NO} ) {
            $episode = $element->{Attributes}{EPISODE_NO};
        } elsif ( $element->{Attributes}{Episode_No} ) {
            $episode = $element->{Attributes}{Episode_No};
        }
        my @list;
        push( @list, $season )  if $season;
        push( @list, $episode ) if $episode;
        my $ext = join( '/', @list );

        $event->{subtitle} = $ext . ' - ' . $event->{subtitle} if length($ext) > 1;

        if ( $element->{Attributes}{SYNOPSIS} ) {
            $event->{synopsis} = $element->{Attributes}{SYNOPSIS};
        } elsif ( $element->{Attributes}{SYNOPSIS2} ) {
            $event->{synopsis} = $element->{Attributes}{SYNOPSIS2};
        }

        $self->{currentEvent} = $event;
    } ## end elsif ( $element->{Name} ...)
    $self->{currentData} = "";
} ## end sub start_element

sub end_element {
    my ( $self, $element ) = @_;
    my $event = $self->{currentEvent};

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

    if ( $element->{Name} eq 'Detail' ) {

        # check if all event data is complete and valid
        my @missing;
        push( @missing, "start" ) unless defined $event->{start};
        push( @missing, "title" ) unless defined $event->{title};

        if ( scalar @missing > 0 ) {
            $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
            return;
        }

        # push to final array
        push( @{ $self->{eventList} }, $event );
        $event = {};

    } ## end if ( $element->{Name} ...)
    return;
} ## end sub end_element

sub set_document_locator {
    my ( $self, $params ) = @_;
    $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
    my $self = shift;

    push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
