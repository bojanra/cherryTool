package cherryEpg::Ingester;

use 5.024;
use utf8;
use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Compare;
use File::Copy;
use File::Find qw(find);
use File::stat;
use Log::Log4perl qw(get_logger);
use Module::Load;
use Moo;
use Path::Class;
use Try::Tiny;
use YAML::XS;
use open qw ( :std :encoding(UTF-8));

my $logger = get_logger('ingester');

has channel => (
  is       => 'ro',
  required => 1,
  isa      => sub {
    die "parser must be defined"
        unless exists $_[0]->{parser};
  }
);

has dump => (
  is      => 'ro',
  default => 0,
);

has parserReady => (
  is      => 'rw',
  default => 0,
);

has 'cherry' => ( is => 'lazy', );
has 'epg'    => ( is => 'lazy', );

sub _build_cherry {
  my ($self) = @_;

  return cherryEpg->instance();
}

sub _build_epg {
  my ($self) = @_;

  # initialize private cherryEpg::Epg object
  # so we can run in parallel
  return $self->cherry->epgInstance;
} ## end sub _build_epg

sub BUILD {
  my ( $self, $args ) = @_;

  $self->{channel_id} = $self->channel->{channel_id};
  $self->{source}     = dir( $self->cherry->config->{core}{ingest}, $self->{channel_id} );
  $self->{codepage}   = $self->channel->{codepage} // "ISO-8859-2";
  $self->{language}   = $self->channel->{language} // 'slv';

  if ( length( $self->{language} ) > 3 ) {
    $logger->fatal( "language code longer than 3 characters [$self->{language}]", $self->{channel_id} );
    exit(1);
  }

  ( $self->{parser}, $self->{parserOption} ) = split( /\?/, $self->channel->{parser} );

  if ( !$self->{parser} ) {
    $logger->error( "missing parser definition", $self->{channel_id} );
    exit(1);
  }

  $self->{parser} = "cherryEpg::Parser::" . $self->{parser};

  try {
    load $self->{parser};
    $self->parserReady(1);
  } catch {
    my $error = $_;
    say $_ if $logger->is_trace();
    $logger->fatal( "loading library [$self->{parser}]", $self->{channel_id}, undef, [$error] );
  };
} ## end sub BUILD

=head3 short_descriptor( $event, $language)

Generate and return short descriptor hash from event.

=cut

sub short_descriptor {
  my ( $self, $event, $language ) = @_;

  my $short_descriptor;

  $short_descriptor->{descriptor_tag} = 0x4d;

  # language code from ISO 639-2 lowercase
  $short_descriptor->{language_code} = $language;

  $event->{title}                 = _prepareTextField( $event->{title} );
  $short_descriptor->{event_name} = $event->{title};

  if ( !defined $short_descriptor->{event_name} ) {
    push( $event->{error}->@*, "codepage conversion of title failed" );
  }

  $event->{subtitle}        = _prepareTextField( $event->{subtitle} // "" );
  $short_descriptor->{text} = $event->{subtitle};

  if ( !defined $short_descriptor->{text} ) {
    push( $event->{error}->@*, "codepage conversion of subtitle failed" );
  }

  return $short_descriptor;
} ## end sub short_descriptor

=head3 languageCodeMap( $3letter)

Convert 3 letter language code to 2 letter.

=cut

sub languageCodeMap {
  my ( $self, $code ) = @_;
  my %languageMapping = (
    ces => 'cz',
    deu => 'de',
    eng => 'en',
    fra => 'fr',
    pol => 'pl',
    rus => 'rs',
    slv => 'sl',
    spa => 'es',
  );

  return $languageMapping{$code} if $languageMapping{$code};
  return $code // 'en';
} ## end sub languageCodeMap

=head3 ingestData( $result )

Ingest all events returned by the parser.

=cut

sub ingestData {
  my ( $self, $result ) = @_;
  my $eventList   = $result->{eventList};
  my $parserError = $result->{errorList}->@*;
  my $ingestError = 0;

  $result->{defined} = $eventList->@*;

  # sort before continue
  @$eventList = sort { $a->{start} <=> $b->{start} } @$eventList;

  # are there events starting at same time
  my $i = 0;
  while ( $i < $#$eventList ) {

    if ( $$eventList[$i]->{start} == $$eventList[ $i + 1 ]->{start} ) {

      # remove first event
      my @overlapped = splice( @$eventList, $i, 1 );
      push( $result->{overlap}->@*, @overlapped );
      next;
    } ## end if ( $$eventList[$i]->...)
    $i += 1;
  } ## end while ( $i < $#$eventList)

  # calculate stop time based on beginning of next event only if no stop defined
  my $duration;

  # walk through all events and set stop of current event to start of next event
  $i = 0;
  while ( $i < scalar(@$eventList) ) {

    # convert duration to stop
    if ( $$eventList[$i]->{duration} and $$eventList[$i]->{duration} > 0 ) {
      $$eventList[$i]->{stop} = $$eventList[$i]->{start} + $$eventList[$i]->{duration};
      $$eventList[$i]->{duration} += 0;    # convert to numeric
    }

    # stop if last event
    last if $i == $#$eventList;

    if ( $$eventList[$i]->{stop} && $$eventList[$i]->{stop} =~ /^\d+$/ ) {

      # check if eventList overlap
      if ( $$eventList[ $i + 1 ]->{start} < $$eventList[$i]->{stop} ) {

        # move the later event to the error log or to the failed event log
        my @overlapped = splice( @$eventList, $i + 1, 1 );
        push( $result->{overlap}->@*, @overlapped );
        next;
      } ## end if ( $$eventList[ $i +...])
    } else {

      # set stop of current event to start of next/following
      $$eventList[$i]->{stop} = $$eventList[ $i + 1 ]->{start};
    }
    $i += 1;
  } ## end while ( $i < scalar(@$eventList...))

  # what about the last event FIXME
  # set the duration of the last event to 15 min.
  if ( !$$eventList[-1]->{stop} || $$eventList[-1]->{stop} !~ /^\d+$/ ) {
    $$eventList[-1]->{stop} = $$eventList[-1]->{start} + 15 * 60;
  }

  my $startOfFirst = $$eventList[0]->{start};
  my $stopOfLast   = $$eventList[-1]->{stop};

  # delete all existing events in database that start during ingested events
  my $d = $self->epg->deleteEvent( $self->{channel_id}, undef, $startOfFirst, $stopOfLast );
  $result->{overwritten_in_db} += $d;

  # or stop during these eventlist
  $d = $self->epg->deleteEvent( $self->{channel_id}, undef, undef, undef, $startOfFirst, $stopOfLast );
  $result->{overwritten_in_db} += $d;

  # or start before and stop after
  $d = $self->epg->deleteEvent( $self->{channel_id}, undef, undef, $startOfFirst, $stopOfLast );
  $result->{overwritten_in_db} += $d;

  # add events to db
  foreach my $event (@$eventList) {

    my $errorFlag = 0;

    # add human readable time information
    $event->{time} = localtime( $event->{start} );

    # do not insert events older that 7 days
    # next if $event->{stop} < ( time() - 7 * 24 * 60 * 60 );

    # check if title missing
    if ( !exists $event->{title} || $event->{title} eq "" ) {
      push( $event->{error}->@*, "missing title" );
      $event->{title} = "-";
    }

    if ( ( $event->{stop} - $event->{start} ) > 24 * 60 * 60 ) {
      push( $event->{error}->@*, "event duration exceeded (>24hours)" );
      $event->{stop} = $event->{start} + 24 * 60 * 60;
    }

    if ( $event->{start} == $event->{stop} ) {
      push( $event->{error}->@*, "event start - stop are identical" );
    }

    if ( $event->{start} > $event->{stop} ) {
      push( $event->{error}->@*, "event stop before start" );
    }

    my $title;
    my $subtitle;
    my $synopsis = $event->{synopsis} // '';
    my $language = $self->{language};

    # build the descriptors
    my @descriptors;

    # short event descriptor
    if ( ref( $event->{title} ) eq 'HASH' ) {

      # multilanguage EIT
      foreach my $language ( keys %{ $event->{title} } ) {
        my $short_descriptor = $self->short_descriptor( {
            title    => $event->{title}{$language},
            subtitle => $event->{subtitle}{$language} // ''
          },
          $language
        );
        push( @descriptors, $short_descriptor );
        $title    = $event->{title}{$language};
        $subtitle = $event->{subtitle}{$language} // '';
      } ## end foreach my $language ( keys...)
      #
    } else {

      # classic simple single language EIT
      $title    = $event->{title}    // '';
      $subtitle = $event->{subtitle} // '';
      my $short_descriptor = $self->short_descriptor( $event, $self->{language} );
      push( @descriptors, $short_descriptor );
    } ## end else [ if ( ref( $event->{title...}))]

    $language = $self->languageCodeMap($language);

    if ( exists $event->{synopsis} && $event->{synopsis} ne "" ) {
      my $extended_descriptor;
      $extended_descriptor->{descriptor_tag} = 0x4e;                # extended event descriptor
      $extended_descriptor->{language_code}  = $self->{language};

      if ( exists $event->{item}
        && exists $event->{item}{description}
        && $event->{item}{description} ne ''
        && exists $event->{item}{text}
        && $event->{item}{text} ne '' ) {

        my $item;
        $item->{description} = _prepareTextField( $event->{item}{description} );
        $item->{text}        = _prepareTextField( $event->{item}{text} );
        if ( defined $item->{description} && defined $item->{text} ) {
          $extended_descriptor->{item} = $item;
        } else {
          push( $event->{error}->@*, "codepage conversion of item description/text failed" );
        }
      } ## end if ( exists $event->{item...})

      $event->{synopsis}           = _prepareTextField( $event->{synopsis} );
      $extended_descriptor->{text} = $event->{synopsis};
      if ( defined $extended_descriptor->{text} ) {
        push( @descriptors, $extended_descriptor );
      } else {
        push( $event->{error}->@*, "codepage conversion of synopsis failed" );
      }
    } ## end if ( exists $event->{synopsis...})

    if ( defined $event->{parental_rating} ) {
      if ( $event->{parental_rating} >= 3 ) {
        my $parental_rating_descriptor;
        $parental_rating_descriptor->{descriptor_tag} = 0x55;    # parental_rating_descriptor

        my $rate;
        $rate->{country_code} = $event->{country_code} || 'SVN';
        $rate->{country_code} = uc( $rate->{country_code} );
        $rate->{rating}       = $event->{parental_rating} - 3;

        push( $parental_rating_descriptor->{list}->@*, $rate );

        push( @descriptors, $parental_rating_descriptor );
      } else {
        push( $event->{error}->@*, "incorrect parental rating - ignored" );
      }
    } ## end if ( defined $event->{...})

    if ( defined $event->{content} ) {
      my $content_descriptor;
      $content_descriptor->{descriptor_tag} = 0x54;    # content descriptor
      $content_descriptor->{list}           = [];

      if ( !ref $event->{content} ) {

        # convert scalar to array
        $event->{content} = [ $event->{content} ];
      }

      if ( ref $event->{content} eq 'ARRAY' ) {
        foreach my $code ( $event->{content}->@* ) {
          if ( $code =~ m/^\d+$/ && $code >= 0 && $code <= 0xff ) {
            push( $content_descriptor->{list}->@*, $code );
          } else {
            push( $event->{error}->@*, "invalid content descriptor [$code] - ignored" );
          }
        } ## end foreach my $code ( $event->...)

        push( @descriptors, $content_descriptor ) if $content_descriptor->{list}->@*;
      } else {
        push( $event->{error}->@*, "incorrect content descriptor format [" . ( ref $event->{content} ) . "] - ignored" );
      }
    } ## end if ( defined $event->{...})

    my $store = {
      start       => $event->{start},
      stop        => $event->{stop},
      channel_id  => $self->{channel_id},
      id          => exists $event->{id} ? $event->{id} : undef,
      descriptors => [@descriptors],
      title       => $title,
      subtitle    => $subtitle,
      synopsis    => $synopsis,
      language    => $language
    };

    $store->{image} = $event->{image} if exists $event->{image};

    if ( defined $self->epg->addEvent($store) ) {
      $result->{added} += 1;
    } else {
      push( $event->{error}->@*, "insert in database failed" );
    }

    # if there were errors save the event to report
    if ( exists $event->{error} && scalar( $event->{error}->@* ) ) {
      push( $result->{errorList}->@*, {%$event} );
      ++$ingestError;
    }
  } ## end foreach my $event (@$eventList)

  return $result;
} ## end sub ingestData

=head3 processFile( $dataFile, $forced = 0)

Process given $dataFile in channel ingest directory. Check regarding MD5 and run parser if required.
$dataFile is complete path to file.
If $forced then ignore existing MD5 file.

=cut

sub processFile {
  my ( $self, $dataFile, $forced ) = @_;

  my $md5File  = $dataFile . ".md5";
  my $ctrlFile = $md5File . ".parsed";

  # update md5 file if not existing or source file newer (last modify)
  if ( !-e $md5File || stat($md5File)->mtime < stat($dataFile)->mtime ) {

    # calculate md5 and save to file
    open( my $data, '<', $dataFile ) || do {
      $logger->error( "read [$dataFile] for MD5", $self->{channel_id} );
      return;
    };
    binmode($data);
    my $md5sum = Digest::MD5->new->addfile(*$data)->hexdigest;
    close($data);

    open( my $chksum, '>', $md5File ) || do {
      $logger->error( "write [$md5File]", $self->{channel_id} );
      return;
    };
    print( $chksum $md5sum );
    close($chksum);
  } ## end if ( !-e $md5File || stat...)

  # check if there is something new
  if ( !-e $ctrlFile || compare( $md5File, $ctrlFile ) != 0 || $forced ) {

    # initialize and see if the parser is really loaded
    my $engine = try {
      return $self->{parser}->new( source => $dataFile, logger => get_logger('parser') );
    } catch {
      $logger->error( "initialize [$self->{parser}]", $self->{channel_id} );
      return;
    };

    return if !$engine;

    $logger->trace( "load parser [$self->{parser}]", $self->{channel_id} );

    # run the parser
    my $result = try {
      $engine->parse( $self->{parserOption} );
    } catch {
      my $error = $_;
      say $error if $logger->is_trace();
      my @reason   = split( /:/, $error );
      my $filename = basename($dataFile);
      $logger->error( "parsing [$dataFile]", $self->{channel_id}, undef, \@reason );
      return;
    };

    return if !$result;

    # count the no events defined
    my $errorCount = $result->{errorList}->@*;
    my $eventCount = $result->{eventList}->@*;

    if ( !$eventCount ) {
      if ($errorCount) {
        $logger->error( "parsed [$result->{source}] with [$errorCount] errors", $self->{channel_id}, undef, $result );
      } else {
        $logger->error( "no events found [$result->{source}]", $self->{channel_id}, undef, $result );
      }
    } else {
      $logger->trace( "found [$eventCount] events, [$errorCount] errors", $self->{channel_id} );
    }

    say( join( "\n", $result->{errorList}->@* ) ) if $errorCount && $logger->is_trace();

    # mark file as parsed
    copy( $md5File, $ctrlFile );

    $result->{added}             = 0;
    $result->{overlap}           = [];
    $result->{overwritten_in_db} = 0;
    $result->{defined}           = 0;

    return $result if !$eventCount;

    # ingest
    $result = $self->ingestData($result);

    my $overlapCount = $result->{overlap}->@*;

    # count the no events defined
    $errorCount = $result->{errorList}->@*;

    if ($errorCount) {
      $logger->warn(
        "ingest ["
            . $result->{added} . "/"
            . ( $result->{defined} - $overlapCount )
            . "] events with ["
            . $errorCount
            . "] error",
        $self->{channel_id}, undef, $result
      );
    } else {
      $logger->info( "ingest [" . $result->{added} . "/" . ( $result->{defined} - $overlapCount ) . "] events",
        $self->{channel_id}, undef, $result );
    }

    if ( $self->dump ) {
      $YAML::XS::QuoteNumericStrings = 0;
      my $output = Dump($result);
      utf8::decode($output);
      say "Parser output:";
      say $output;
    } ## end if ( $self->dump )

    return $result;
  } else {
    return;
  }
} ## end sub processFile

=head3 walkDir()

Walk through channel source directory and find files to be processed.

Return reference to updated files.

=cut

sub walkDir {
  my ($self) = @_;

  my $workingDir = $self->{source};
  my @doneFiles;
  my $ingestCount = 0;

  return unless -d $workingDir;

  find( {
      wanted => sub {

        # skip directories
        return if -d $_;

        # show just non md5 files
        return if /\.md5/;

        # skip "hidden" files starting with a dot
        return if /\/\./;

        push( @doneFiles, $self->processFile($_) );
      },
      no_chdir => 1
    },
    $workingDir
  );

  return \@doneFiles;
} ## end sub walkDir

=head3 _prepareTextField( $text)

Prepare (precorrect) text field and check if later conversion to target codepage can be done without errors.
Return field or undef if failed.

=cut

sub _prepareTextField {
  my $text = shift;

  return "" if $text eq "";

  # remove repetition of spaces
  $text =~ s/ +/ /sg;

  # reduce combination of multiple \n and \r to single \n
  $text =~ s/[\r\n]+/\n/sg;

  # remove leading \n and \s
  $text =~ s/^[\n\s]+//sg;

  # remove tailing \n and \s
  $text =~ s/[\n\s]+$//sg;

  # remove leading spaces in line
  $text =~ s/^\s$//mg;

  # ...
  $text =~ s/\x{2026}/.../sg;

  # replace incorrect used quote sign, quotation mark, inverted comma
  $text =~ s/\x{00bb}/"/sg;
  $text =~ s/\x{00ab}/"/sg;
  $text =~ s/\x{2018}/'/sg;
  $text =~ s/\x{2019}/'/sg;
  $text =~ s/\x{201a}/'/sg;
  $text =~ s/\x{201b}/'/sg;
  $text =~ s/\x{201c}/"/sg;
  $text =~ s/\x{201d}/"/sg;
  $text =~ s/\x{201e}/"/sg;
  $text =~ s/\x{201f}/"/sg;

  # change various dash types to minus
  $text =~ s/[\x{2010}-\x{2015}]/-/sg;

  # change Supplemental Punctuation to \n
  $text =~ s/[\x{2e00}-\x{2e7f}]/\n/sg;

  return $text;
} ## end sub _prepareTextField

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
