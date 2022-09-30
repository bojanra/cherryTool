package cherryEpg::Parser::AMCXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.24';

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

    my $handler = AMCXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package AMCXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Carp qw( croak );

sub new {
    my $this  = shift;
    my $class = ref($this) || $this;
    my $self  = {};

    bless( $self, $class );
    return $self;
} ## end sub new

sub start_document {
    my ($self) = @_;

    # this will be the events
    $self->{eventList} = [];

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ( $self, $element ) = @_;

    $self->{report}            = $self->{'_parser'}->{output};
    $self->{report}{eventList} = $self->{eventList};
    $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} eq 'ROW' ) {
        $self->{currentEvent} = {};
    }

    $self->{currentData} = "";
} ## end sub start_element

sub characters {
    my ( $self, $element ) = @_;

    $self->{currentData} .= $element->{Data};
}

sub end_element {
    my ( $self, $element ) = @_;
    my $value = $self->{currentData};
    my $event = $self->{currentEvent};

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
        /EPG_NAME/ && do {
            $event->{title} = $value;
            return;
        };
        /DEAL_NAME/ && do {

            # swap The from the end
            $value =~ s/^(.*), (The.*)$/$2 $1/;

            # swap A
            $value =~ s/^(.*), (A)$/$2 $1/;
            $event->{subtitle} = $value;
            return;
        };
        /EPG_SYNOPSIS/ && do {
            $value =~ s/[\n\r]+$//;
            $event->{synopsis} = $value;
            return;
        };
        /CERT_MAP1/ && do {

            # parental rating (12+)
            if ( $value =~ /\((\d+)\+\)/ ) {
                $event->{parental_rating} = $1;
            }
            return;
        };
        /DURATION/ && do {

            # duration in minutes
            if ( $value =~ /(\d+)/ ) {
                $event->{duration} = $1 * 60;
            } else {
                $self->error("Duration not valid number [$value]");
            }
            return;
        };
        /SCHEDULE_DATE/ && do {
            if ( $value =~ /(\d{4}-\d{2}-\d{2})/ ) {
                $event->{date} = $1;
            } else {
                $self->error("Start date incorrect [$value]");
            }
            return;
        };
        /START_TIME/ && do {
            if ( $value =~ /(\d{2}:\d{2})/ ) {
                $event->{time} = $1;
            } else {
                $self->error("Start time incorrect [$value]");
            }
            return;
        };
        /CAST/ && do {
            if ( $value ne '' ) {
                if ( exists $event->{cast} ) {
                    $event->{cast} .= ', ' . $value;
                } else {
                    $event->{cast} = $value;
                }
            } ## end if ( $value ne '' )
            return;
        };
        /ROW$/ && do {

            # add the event to the list
            $self->addEvent();
            return;
        };
    } ## end SWITCH: for ( $element->{Name} )
    return;
} ## end sub end_element

sub set_document_locator {
    my ( $self, $params ) = @_;
    $self->{'_parser'} = $params->{'Locator'};
}

sub error {
    my $self = shift;

    push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

sub addEvent {
    my $self  = shift;
    my $event = $self->{currentEvent};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "date" )  unless defined $event->{date};
    push( @missing, "time" )  unless defined $event->{time};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
        $self->error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    my $start = localtime->strptime( $event->{date} . " " . $event->{time}, "%Y-%m-%d %H:%M" );

    # stupid TV day count correction
    $start += ONE_DAY if $start < $self->{last};
    $self->{last} = $start;

    $event->{start} = $start->epoch;

    $event->{synopsis} .= "\nIgralci: " . $event->{cast} if $event->{cast};
    delete $event->{date};
    delete $event->{cast};
    delete $event->{time};

    return if $event->{title} eq "END";

    # push to final array
    push( @{ $self->{eventList} }, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
