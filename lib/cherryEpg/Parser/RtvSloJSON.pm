package cherryEpg::Parser::RtvSloJSON;

use 5.024;
use utf8;
use JSON::XS;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.28';

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

  my $json = JSON::XS->new->decode($content);

  if ( !$json ) {
    $self->error("Content not in JSON format");
    return $report;
  }

  foreach my $e ( @{ $json->{response} } ) {

    # skip blocks
    next if exists $e->{flags}{is_block} && $e->{flags}{is_block} == 1;

    my $year;
    my $month;
    my $day;
    my $event;
    my @subTitles;

    if ( defined $e->{broadcast}{title} && $e->{broadcast}{title} ne "" ) {
      $event->{title} = $e->{broadcast}{title};
      push( @subTitles, $e->{broadcast}{eptitle} ) if defined $e->{broadcast}{eptitle} && $e->{broadcast}{eptitle} ne "";
    } elsif ( defined $e->{broadcast}{eptitle} && $e->{broadcast}{eptitle} ne "" ) {
      $event->{title} = $e->{broadcast}{eptitle};
    } elsif ( defined $e->{broadcast}{slottitle} && $e->{broadcast}{slottitle} ne "" ) {
      $event->{title} = $e->{broadcast}{slottitle};
    }
    if ( defined $e->{broadcast}{subtitle} && $e->{broadcast}{subtitle} ne "" ) {
      push( @subTitles, $e->{broadcast}{subtitle} );
    }

    push( @subTitles, "ponovitev" ) if $e->{flags}{is_repeat};

    $event->{subtitle} = join( ', ', @subTitles ) if scalar(@subTitles) > 0;

    if ( exists $e->{flags}{withparents} ) {
      my $flag = $e->{flags}{withparents};

      # Broadcast is not suitable for kids and youth up to age 15.
      if ( $flag == 2 ) {
        $event->{parental_rating} = 13;
      }

      # Broadcast is not suitable for kids and youth up to age 12.
      elsif ( $flag == 3 ) {
        $event->{parental_rating} = 10;
      }

      # For adults only.
      elsif ( $flag == 4 ) {
        $event->{parental_rating} = 15;
      }
    } ## end if ( exists $e->{flags...})

    $event->{synopsis} = $e->{napovednik} // "";

    $event->{id} = $e->{id};

    if ( $e->{duration} ) {
      $event->{duration} = $e->{duration};
    }

    # 2022-01-10 00:20:00
    my $t = localtime->strptime( $e->{stamp_real}, "%Y-%m-%d %H:%M:%S" );
    if ( !$t ) {
      $self->error( "Unknown timestamp format [" . $e->{stamp_real} . "]" );
      next;
    } else {
      $event->{start} = $t->epoch;
    }

    $self->smartCorrect($event);

    push( @{ $report->{eventList} }, $event );
  } ## end foreach my $e ( @{ $json->{...}})

  return $report;
} ## end sub parse

=head3 smartCorrect( )

Fix some stupid failures.

=cut

sub smartCorrect {
  my ( $self, $event ) = @_;

  if ( !defined $event->{synopsis} ) {
    delete $event->{synopsis};
  }

  return if !$event->{title};

  if ( $event->{title} eq "Dnevnik"
    && $event->{synopsis} =~ /^Z ogledom DNEVNIKA/ ) {
    $event->{synopsis} = "Prerez dnevnega dogajanja v Sloveniji in po svetu";
  }

  if ( $event->{title} eq "Prvi dnevnik"
    && $event->{synopsis} =~ /^V Prvem dnevniku/ ) {
    delete $event->{synopsis};
  }

  if ( $event->{title} eq "Slovenska kronika"
    && $event->{synopsis} =~ /^Oddaja Slovenska kronika vsak delo/ ) {
    delete $event->{synopsis};
  }

  if ( $event->{title} eq "Vreme"
    && $event->{synopsis} =~ /^Vreme je na sporedu vsak/ ) {
    delete $event->{synopsis};
  }

  if (
    $event->{title} eq "Šport"
    && ( $event->{synopsis} =~ /^Osrednja dnevno/
      || $event->{synopsis} =~ /^V prvih dnevnih/ )
      ) {
    delete $event->{synopsis};
  } ## end if ( $event->{title} eq...)

  if ( $event->{title} eq "Poročila"
    && $event->{synopsis} =~ /^V Prvem dnevniku/ ) {
    delete $event->{synopsis};
  }

  if ( exists $event->{synopsis} && defined $event->{synopsis} ) {
    $event->{synopsis} =~ s/[ \n\r]+$//s;
    $event->{synopsis} =~ s/ *[\n\r]+/\n/s;
  }
} ## end sub smartCorrect

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
