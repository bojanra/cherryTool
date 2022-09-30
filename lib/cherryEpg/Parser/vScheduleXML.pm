package cherryEpg::Parser::vScheduleXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.26';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => hash of arrays of events found

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $handler = vScheduleXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package vScheduleXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;
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
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;
    my $linecount = $self->{_parser}->location()->{'LineNumber'};

    if ( $element->{Name} eq 'Event' ) {
        if ( $element->{Attributes}{Type} eq 'video' ) {
            my $event;

            # get start Start="07/05/2022 14:16:16"
            my $start = try { localtime->strptime( $element->{Attributes}{Start}, "%d/%m/%Y %H:%M:%S" )->epoch; };
            if ( !$start ) {
                $self->_error( "Incorrect date/time format [" . $element->{Attributes}{Start} . "] in line " . $linecount );
                return;
            }

            # get duration EventDuration="00:00:42.6460000"
            my $duration;

            if ( $element->{Attributes}{EventDuration} =~ m|^(\d+):(\d+):(\d+)\.| ) {
                $duration = $3 + 60 * ( $2 + 60 * $1 );
            }

            my $transition = $element->{Attributes}{TransitionTime} // 0;
            $transition /= 1000;

            $event->{start} = $start;
            if ( defined $duration ) {
                $event->{duration} = $duration - $transition;
            }
            $event->{title} = $element->{Attributes}{Title} if $element->{Attributes}{Title};

            # check if all event data is complete and valid
            my @missing;
            push( @missing, "start" ) unless defined $event->{start};
            push( @missing, "title" ) unless defined $event->{title};

            if ( scalar @missing > 0 ) {
                $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $linecount );
                return;
            }

            # push to final array
            push( $self->{eventList}->@*, $event );

        } else {
            $self->_error( "Not video event in line " . $linecount );
        }
    } ## end if ( $element->{Name} ...)
} ## end sub start_element

sub set_document_locator {
    my ( $self, $params ) = @_;
    $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
    my $self = shift;

    push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
