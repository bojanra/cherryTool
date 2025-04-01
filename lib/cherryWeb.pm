package cherryWeb;

use 5.024;
use cherryEpg::Git;
use cherryEpg::Maintainer;
use cherryEpg::Scheme;
use cherryEpg;
use Dancer2;
use Dancer2::Plugin::Auth::Extensible;
use DBI qw(:sql_types);
use Digest::MD5;
use File::Temp qw(tempfile);
use Gzip::Faster;
use Path::Class;
use Sys::Hostname;
use Time::Piece;
use JSON::XS qw();

my $cherry = cherryEpg->instance();

my $CHERRY_TEMPDIR = File::Temp->newdir( 'cherry_XXXXXX', TMPDIR => 1, CLEANUP => 1 );

hook before => sub {

};

hook before_template_render => sub {
  my $tokens = shift;
  my $user   = session 'logged_in_user';
  $tokens->{user}        = $user;
  $tokens->{hostname}    = hostname;
  $tokens->{description} = setting('description');
}; ## end before_template_render => sub

sub loginPageHandler {
  my $return_url = params->{return_url} // '';
  template 'login' => { hostname => hostname };
}

any '/logout' => sub {
  app->destroy_session;
  template 'goodbye';
};

hook after_login_success => sub {
  redirect request->path;
};

# the Dashboard
get '/' => require_role 'cherryweb' => sub {
  template 'dashboard' => { menu => 'dashboard' };
};

# log browser page
get '/log' => require_role 'cherryweb' => sub {
  template 'log' => { menu => 'log' };
};

# scheme
get '/scheme' => require_role 'cherryweb' => sub {
  template 'scheme' => { menu => 'scheme' };
};

# carousel manager
get '/carousel' => require_role 'cherryweb' => sub {
  template 'carousel' => { menu => 'carousel' };
};

# announcement
get '/announce' => require_role 'cherryweb' => sub {
  template 'announce' => { menu => 'announce' };
};

# show system info
get '/system' => require_role 'cherryweb' => sub {
  template 'system' => { menu => 'system' };
};

# get reference xls file
get '/scheme/reference' => require_role cherryweb => sub {
  my $file = '/var/lib/cherryepg/cherryTool/t/scheme/sample.xls';
  pass and return false unless -f $file;
  send_file( $file, system_path => 1, filename => 'sample.xls' );
};

# generate system info report for monitoring
get '/report.:format' => sub {
  my $format = params->{'format'};

  my $cherry = cherryEpg->instance();

  if ( $format eq "txt" ) {
    send_file( \$cherry->format(), content_type => 'text/plain; charset=UTF-8' );
  } elsif ( $format eq "json" ) {
    send_as( JSON => $cherry->report() );
  } else {
    return "The [$format] format is not yet supported. ";
  }
}; ## end '/report.:format' => sub

# get events for single, group or all channels in xmltv format
get '/export/:id.xml' => sub {
  my $channel_id = params->{id};
  my $custom     = params->{custom};

  my $cherry = cherryEpg->instance();

  my $list;

  if ( $channel_id eq "all" ) {
    $list = $cherry->epg->listChannel();
  } elsif ( $channel_id =~ m/^\d+$/ ) {
    $list = $cherry->epg->listChannel($channel_id);
  } else {
    send_error( "Not allowed", 404 );
  }

  return "" unless $list;

  response_header( 'Content-Type' => 'application/xml' );
  return $cherry->epg->export2XMLTV( $list, $cherry->config->{core}{exportIP}, $custom );
}; ## end '/export/:id.xml' => sub

# get events for single channel in standard or custom csv format
get '/export/:id.csv' => sub {
  my $channel_id = params->{id};
  my $custom     = params->{custom};

  my $cherry = cherryEpg->instance();

  my $channel = $cherry->epg->listChannel($channel_id)->[0];

  response_header( 'Content-Type' => 'text/csv; charset=UTF-8' );
  return $cherry->epg->export2CSV( $channel, $custom );
}; ## end '/export/:id.csv' => sub

# download scheme by target
get '/scheme/:target' => require_role cherryweb => sub {
  my $target = params->{target};

  my $scheme = cherryEpg::Scheme->new();
  my $s      = $scheme->restore($target);

  if ($s) {
    send_file( \$s->{source}{blob}, filename => $s->{source}{filename}, content_type => 'application/excel' );
  } else {
    send_error( "Sorry, requested scheme not found!", 404 );
  }
}; ## end cherryweb => sub

# download chunk by target
get '/carousel/:target' => require_role cherryweb => sub {
  my $target = params->{target};

  my $player = cherryEpg::Player->new();
  my ( $a, undef, undef, undef, undef, $serialized ) = $player->load( '/', $target );

  if ($$serialized) {
    my $gzipped = gzip($$serialized);
    send_file( \$gzipped, filename => $target . '.ets.gz', content_type => 'application/octet-stream' );
  } else {
    send_error( "Sorry, requested chunk not found!", 404 );
  }
}; ## end cherryweb => sub

# run chunk through dvbsnoop and return result
get '/dump/:target' => require_role cherryweb => sub {
  my $target = params->{target};

  my $player = cherryEpg::Player->new();
  my $dump   = $player->dump( '/', $target );

  send_file( $dump, filename => $target . '.txt', content_type => 'text/plain; charset=UTF-8' );
}; ## end cherryweb => sub

# from here on there are the 'AJAX' handlers
# status
post '/status' => require_role cherryweb => sub {
  my $report = cherryEpg->instance()->report();

  # correct timestamp/uptime format display with TIMEAGO
  my $timestamp = localtime( $report->{timestamp} );
  $report->{timestamp} = $timestamp->strftime();
  my $systemStart = localtime( time - $report->{uptime} );
  $report->{systemStart} = $systemStart->datetime();

  send_as( JSON => $report );
}; ## end cherryweb => sub

post '/announce' => require_role cherryweb => sub {

  my $config = params->{config};

  my $epg = cherryEpg->instance()->epg;

  if ($config) {

    # update
    my $newConfig = {
      present => {
        text    => params->{present} // '',
        publish => params->{present_check} ? 1 : 0,
      },
      following => {
        text    => params->{following} // '',
        publish => params->{following_check} ? 1 : 0,
      }
    };
    if ( $epg->announcerSave($newConfig) && $cherry->deleteSection() ) {
      send_as(
        JSON => {
          success  => 1,
          announce => $newConfig
        }
      );
    } else {
      send_as( JSON => { success => 0 } );
    }
  } else {

    # just status
    send_as(
      JSON => {
        success  => 1,
        announce => $epg->announcerLoad()
      }
    );
  } ## end else [ if ($config) ]
}; ## end cherryweb => sub

post '/carousel/browse' => require_role cherryweb => sub {

  my $list = cherryEpg::Player->new()->list('/');

  # convert date to ISO 8601 for use with timeago
  foreach my $item ( $list->@* ) {
    $item->{timestamp} = localtime( $item->{timestamp} )->datetime;
  }

  send_as( JSON => $list );
}; ## end cherryweb => sub

post '/carousel/delete' => require_role cherryweb => sub {
  my $target = params->{target};

  my $player = cherryEpg::Player->new();

  my $report = $player->delete( '/', $target );

  send_as( JSON => { success => $report // 0, target => $target } );
}; ## end cherryweb => sub

post '/carousel/pause' => require_role cherryweb => sub {
  my $target = params->{target};

  my $player = cherryEpg::Player->new();

  if ( $player->stop( '/', $target ) ) {
    send_as( JSON => { success => 1, target => $target } );
  }

  send_as( JSON => { success => 0 } );
}; ## end cherryweb => sub

post '/carousel/play' => require_role cherryweb => sub {
  my $target = params->{target};

  my $player = cherryEpg::Player->new();

  if ( $player->arm( '/', $player->load( '/', $target ) ) ) {

    my $report = $player->play( '/', $target );

    if ($report) {
      send_as( JSON => { success => 1, target => $target } );
    }
  } ## end if ( $player->arm( '/'...))

  send_as( JSON => { success => 0 } );
}; ## end cherryweb => sub

post '/carousel/upload' => require_role cherryweb => sub {
  my $upload = request->upload('file');

  if ( !$upload ) {
    send_as( JSON => { success => 0 } );
  }

  my $filename = $upload->filename;
  my $tempname = $upload->tempname;

  my $player = cherryEpg::Player->new();
  my @raw    = $player->load($tempname);
  my $report;

  # when the builder fails, we generate a simulated report
  if ( !@raw ) {
    $report = {
      error  => ["Invalid file. Please contact support."],
      source => $filename
    };
  } else {

    my $md5 = Digest::MD5::md5_hex( ${ $raw[5] } );

    my $file;
    ( undef, $file ) = tempfile( 'chunkXXXXXX', OPEN => 1, UNLINK => 0, SUFFIX => '.yaml.gz', DIR => $CHERRY_TEMPDIR );

    $upload->copy_to($file);

    # save the temporary filename
    session chunkFile => $file;

    $report           = $raw[1];
    $report->{md5}    = $md5;
    $report->{size}   = length( ${ $raw[2] } );
    $report->{error}  = [];
    $report->{source} = $filename;
  } ## end else [ if ( !@raw ) ]
  send_as( JSON => $report );
}; ## end cherryweb => sub

post '/carousel/save' => require_role cherryweb => sub {
  my $md5 = params->{md5};

  my $file = session 'chunkFile';

  if ( -e $file ) {
    my $player       = cherryEpg::Player->new();
    my @raw          = $player->load($file);
    my $md5Reference = Digest::MD5::md5_hex( ${ $raw[5] } );

    if ( $md5 eq $md5Reference ) {
      if ( $player->save( '/', $file ) ) {
        unlink($file);
        send_as( JSON => { success => 1 } );
      }
    } ## end if ( $md5 eq $md5Reference)
    unlink($file);
  } ## end if ( -e $file )

  send_as( JSON => { success => 0 } );
}; ## end cherryweb => sub

post '/carousel/upnsave' => require_role cherryweb => sub {
  my @multi = request->upload('file');

  if ( !scalar @multi ) {
    send_as( JSON => [ { success => 0, message => 'Upload failed' } ] );
  }

  my @report = ();
  my $player = cherryEpg::Player->new();

  foreach my $upload (@multi) {
    if ( $player->load( $upload->tempname ) and my $target = $player->save( '/', $upload->tempname ) ) {
      push( @report, { success => 1, message => $upload->filename . ' saved', target => $target } );
    } else {
      push( @report, { success => 0, message => $upload->filename . ' failed' } );
    }
  } ## end foreach my $upload (@multi)

  send_as( JSON => \@report );
}; ## end cherryweb => sub

post '/scheme/upload' => require_role cherryweb => sub {
  my $upload = request->upload('file');

  if ( !$upload ) {
    send_as( JSON => { errorList => ["Upload failed"] } );
  }

  my $filename = $upload->filename;
  my $tempname = $upload->tempname;

  my $scheme = cherryEpg::Scheme->new();
  $scheme->readXLS($tempname);

  my $raw = $scheme->build();

  my $report;

  # when the builder fails, we generate a simulated report
  if ( !$raw ) {
    $report = {
      errorList => ["Error parsing scheme file. Please contact support."],
      source    => $filename
    };
  } else {

    # remember "original" filename
    $scheme->{scheme}{source}{filename} = $filename;

    my $file;
    ( undef, $file ) = tempfile( 'schemeXXXXXX', OPEN => 1, UNLINK => 0, SUFFIX => '.yaml.gz', DIR => $CHERRY_TEMPDIR );

    $scheme->exportScheme($file);

    # save the temporary filename
    session schemeFile => $file;

    $report = {
      channel     => scalar $raw->{channel}->@*,
      eit         => scalar $raw->{eit}->@*,
      rule        => scalar $raw->{rule}->@*,
      source      => $filename,
      description => $raw->{source}{description} // '',
      mtime       => $raw->{source}{mtime},
      errorList   => $scheme->error
    };
  } ## end else [ if ( !$raw ) ]
  send_as( JSON => $report );
}; ## end cherryweb => sub

post '/scheme/browse' => require_role cherryweb => sub {

  my $list = cherryEpg::Scheme->new()->listScheme();

  # convert date to ISO 8601 for use with timeago
  foreach my $item ( $list->@* ) {
    $item->{timestamp} = localtime( $item->{timestamp} )->datetime;
  }

  send_as( JSON => $list );
}; ## end cherryweb => sub

post '/scheme/validate' => require_role cherryweb => sub {
  my $description = params->{description};
  my $mtime       = params->{mtime};

  my $file = session 'schemeFile';

  if ( -e $file ) {
    my $scheme = cherryEpg::Scheme->new();
    if ( $scheme->importScheme($file) ) {
      if ( $mtime eq $scheme->{scheme}{source}{mtime} ) {
        $scheme->{scheme}{source}{description} = $description;
        $scheme->exportScheme($file);

        send_as(
          JSON => {
            success     => 1,
            description => $description
          }
        );
      } ## end if ( $mtime eq $scheme...)
    } ## end if ( $scheme->importScheme...)
    unlink($file) if -e $file;
  } ## end if ( -e $file )
  send_as( JSON => { success => 0 } );
}; ## end cherryweb => sub

post '/scheme/prepare' => require_role cherryweb => sub {
  my $target = params->{target};

  my $scheme = cherryEpg::Scheme->new();

  my $raw = $scheme->restore($target);

  my $report;

  if ( !$raw ) {
    $report = {
      errorList => ["Error preparing scheme file. Please contact support."],
      source    => $target
    };
  } else {

    my $file;
    ( undef, $file ) = tempfile( 'schemeXXXXXX', OPEN => 1, UNLINK => 0, SUFFIX => '.yaml.gz', DIR => $CHERRY_TEMPDIR );

    $scheme->exportScheme($file);

    # save the temporary filename
    session schemeFile => $file;

    $report = {
      channel     => scalar $raw->{channel}->@*,
      eit         => scalar $raw->{eit}->@*,
      rule        => scalar $raw->{rule}->@*,
      source      => $raw->{source}{filename},
      description => $raw->{source}{description},
      mtime       => $raw->{source}{mtime},
      errorList   => $scheme->error
    };
  } ## end else [ if ( !$raw ) ]
  send_as( JSON => $report );
}; ## end cherryweb => sub

post '/scheme/action' => require_role cherryweb => sub {
  my $action = params->{action};
  my $file;
  my $scheme;
  my @report = ();
  my $cherry = cherryEpg->instance();

  if ( $action eq 'maintain' ) {

  } elsif ( $action eq 'loadScheme' ) {
    $file = session 'schemeFile';

    if ( -e $file ) {
      $scheme = cherryEpg::Scheme->new();

      # try to load and compare timestamp
      if ( !$scheme->importScheme($file) or params->{mtime} ne $scheme->{scheme}{source}{mtime} ) {

        # if failed
        unlink($file);
        send_as( JSON => [ { success => 0, message => 'Loading scheme' } ] );
      } ## end if ( !$scheme->importScheme...)
    } else {
      send_as( JSON => [ { success => 0, message => 'Loading file' } ] );
    }
  } else {
    send_as( JSON => [ { success => 0, message => 'Unknown action' } ] );
  }

  # stop all current building processes started by cronjob
  `pgrep -f "cherryTool -B" | xargs -L1 kill`;
  `pgrep -f "cherryTool -G" | xargs -L1 kill`;

  # let's continue

  my $player = cherryEpg::Player->new();

  if ( $action ne 'loadScheme' and params->{deleteCarousel} ) {
    push( @report, { success => defined $player->delete('/'), message => 'Delete carousel' } );
  }

  if ( $action eq 'loadScheme' && !params->{stopCarousel} ) {
    push( @report, { success => defined $player->stop('EIT'), message => 'Stop EIT in carousel' } );
  }

  if ( params->{stopCarousel} ) {
    push( @report, { success => defined $player->stop(), message => 'Stop carousel' } );
  }

  if ( $action eq 'loadScheme' and params->{resetDatabase} ) {
    push( @report, { success => defined $cherry->resetDatabase(), message => 'Reset tables in database' } );
  }

  if ( params->{deleteIngest} ) {
    push( @report, { success => defined $cherry->deleteIngest(), message => 'Delete ingest directory' } );
  }

  if ( ( $action eq 'loadScheme' and !params->{deleteIngest} ) or params->{reIngest} ) {
    push( @report, { success => defined $cherry->resetChannel(), message => 'Reset ingest directory' } );
  }

  if ( $action eq 'loadScheme' ) {
    my ( $success, $error ) = $scheme->pushScheme();
    $scheme->backup();
    push( @report, { success => $success, message => "Load scheme (" . $error->@* . " errors)" } );
    unlink($file);
  } ## end if ( $action eq 'loadScheme')

  if ( params->{grab} || params->{ingest} ) {
    my $count = scalar $cherry->parallelGrabIngestChannel( 'all', params->{grab}, params->{ingest} )->@*;

    my @job;
    push( @job,    'grab' )   if params->{grab};
    push( @job,    'ingest' ) if params->{ingest};
    push( @report, { success => defined $count, message => join( '&', @job ) } );
  } ## end if ( params->{grab} ||...)

  if ( params->{build} ) {
    push( @report, { success => defined $cherry->parallelUpdateEit(), message => 'Build output EIT' } );
  }

  if ( !scalar @report ) {
    push( @report, { success => 1, message => 'Nothing to-do' } );
  }

  send_as( JSON => \@report );
}; ## end cherryweb => sub

post '/scheme/delete' => require_role cherryweb => sub {
  my $target = params->{target};

  my $scheme = cherryEpg::Scheme->new();

  my $report = $scheme->delete($target);

  send_as( JSON => { success => $report // 0, target => $target } );
}; ## end cherryweb => sub

# current configuration
post '/scheme' => require_role cherryweb => sub {
  my $active = shift cherryEpg::Scheme->new()->listScheme()->@*;

  if ($active) {
    $active->{timestamp} = localtime( $active->{timestamp} )->strftime();
  }

  send_as( JSON => $active );
}; ## end cherryweb => sub

# show event budget for future/past
post '/ebudget' => require_role cherryweb => sub {
  my $t = localtime;

  my $cherry = cherryEpg->instance();

  if ( $cherry->isLinger() ) {

    send_as(
      JSON => {
        linger    => 1,
        status    => 0,
        timestamp => $t->strftime(),
      }
    );
  } else {

    my $budget = $cherry->eventBudget();

    send_as(
      JSON => {
        status    => 3,
        timestamp => $t->strftime(),
      }
        )
        unless $budget;

    # convert date to ISO 8601 for use with timeago and get overall
    # worsed status
    my $status = 0;
    foreach my $channel (@$budget) {
      $status = $channel->{status} if $status < $channel->{status};
      if ( $channel->{update} ) {
        my $t = localtime( $channel->{update} );
        $channel->{update} = $t->datetime;
      } else {
        $channel->{update} = undef;
      }
    } ## end foreach my $channel (@$budget)

    send_as(
      JSON => {
        data      => $budget,
        status    => $status,
        timestamp => $t->strftime(),
      }
    );
  } ## end else [ if ( $cherry->isLinger...)]
}; ## end cherryweb => sub

# ingest service eventdata file
post '/ingest/:hash/:id' => sub {
  my $channel_id = params->{id};
  my $hash       = params->{hash};
  my $upload     = request->upload('file');
  my $response   = { success => 0 };

  my $cherry = cherryEpg->instance();

  my $channel = $cherry->epg->listChannel($channel_id)->[0];

  if ( $channel && $channel->{post} && $channel->{post} eq $hash ) {
    if ($upload) {
      if ( ref($upload) ne 'ARRAY' ) {
        $upload = [$upload];
      }
      my $failed;
      my @message;
      my $count    = 0;
      my $grabber  = cherryEpg::Grabber->new( channel => $channel );
      my $ingester = cherryEpg::Ingester->new( channel => $channel );

      foreach my $file ( $upload->@* ) {
        my $filename = $file->filename;
        my $tempname = $file->tempname;
        my $cherry   = cherryEpg->instance();

        if ( !$grabber->move( $tempname, $filename ) ) {
          $failed += 1;
          push( @message, "Transporting of [$filename] failed" );
        } else {
          my $filepath = "" . file( $grabber->{destination}, $filename );
          my $report   = $ingester->processFile( $filepath, 1 );

          if ( !$report ) {
            $failed += 1;
            push( @message, "Ingest of [$filename] failed" );
          } elsif ( $report->{errorList}->@* ) {
            push( @message,
                    "["
                  . $report->{eventList}->@*
                  . "] events ingested with " . "["
                  . $report->{errorList}->@*
                  . "] errors from [$filename]" );
          } else {
            push( @message, "[" . $report->{eventList}->@* . "] events ingested from [$filename]" );
          }
        } ## end else [ if ( !$grabber->move( ...))]
      } ## end foreach my $file ( $upload->...)
      $response->{success} = $failed ? 0 : 1;
      $response->{message} = join( ', ', @message );
    } else {
      $response->{message} = "Uploading eventdata failed";
    }
  } else {
    $response->{message} = "Incorrect hash or channel_id";
  }
  send_as( JSON => $response );
}; ## end '/ingest/:hash/:id' => sub

# return service info
post '/service/info' => require_role cherryweb => sub {
  my $channel_id = params->{id};

  my $cherry = cherryEpg->instance();

  # get info
  my $channel = $cherry->epg->listChannel($channel_id)->[0];
  my $last    = $cherry->epg->listChannelLastUpdate();

  # extract parser option from parser string
  if ( $channel->{parser} =~ s/\?(.*)$// ) {
    $channel->{option} = $1;
  } else {
    $channel->{option} = '';
  }

  my $now = time();

  # get events
  my $eventList = $cherry->epg->listEvent( $channel_id, undef, undef, $now );
  splice( $eventList->@*, 2 );

  # if present is missing
  if ( $eventList->@* == 0 || $eventList->@* > 0 && $eventList->[0]->{start} > $now ) {

    # this is not the present event
    unshift( $eventList->@*, {} );
    splice( $eventList->@*, 2 );
  } ## end if ( $eventList->@* ==...)

  # if following is missing
  push( $eventList->@*, {} ) if $eventList->@* == 1;

  foreach my $event ( $eventList->@* ) {
    $event->{timeSpan} = '?';
    if ( $event->{start} ) {
      $event->{timeSpan} =
          localtime( $event->{start} )->strftime("%H:%M:%S") . ' - ' . localtime( $event->{stop} )->strftime("%H:%M:%S");
    }
    $event->{title}    = '-';
    $event->{subtitle} = '-';
    foreach my $desc ( $event->{descriptors}->@* ) {
      if ( exists $desc->{event_name} ) {
        $event->{title}    = $desc->{event_name};
        $event->{subtitle} = $desc->{text} || '-';
        last;
      }
    } ## end foreach my $desc ( $event->...)
    delete $event->{descriptors};
  } ## end foreach my $event ( $eventList...)


  $channel->{last}   = localtime( $last->{$channel_id}{timestamp} )->strftime();
  $channel->{events} = $eventList;

  send_as( JSON => $channel );
}; ## end cherryweb => sub

# show ringelspiel statistics
post '/carousel' => require_role cherryweb => sub {
  my $cherry = cherryEpg->instance();

  send_as( JSON => $cherry->ringelspiel );
};

# browse log
post '/log' => require_role cherryweb => sub {
  my $draw     = params->{draw}     // 99;
  my $start    = params->{start}    // 0;
  my $limit    = params->{'length'} // 0;
  my $category = params->{category} // '';
  my $level    = params->{level}    // 0;
  my $channel  = params->{channel};

  my $cherry = cherryEpg->instance();
  my $t      = localtime;

  # change the filter string to a list
  my @categoryList = split( /,/, $category );

  # grep only numbers
  @categoryList = sort grep( /\d/, @categoryList );

  my ( $total, $filtered, $listRef ) = $cherry->epg->getLogList( \@categoryList, $level, $start, $limit, $channel );

  send_as(
    JSON => {
      draw            => $draw,
      recordsTotal    => $total    // 0,
      recordsFiltered => $filtered // 0,
      data            => ref($listRef) eq 'ARRAY' ? $listRef : [],
      timestamp       => $t->strftime()
    }
  );
}; ## end cherryweb => sub

# working with the repo
post '/git' => require_role cherryweb => sub {

  my $status = params->{update} // 0;

  my $git = cherryEpg::Git->new();

  if ( !$git ) {
    send_as(
      JSON => {
        success => 0,
        message => "Problem with repository"
      }
    );
  } ## end if ( !$git )

  if ( $status == 0 ) {
    my $s = $git->update();

    if ( !$s->{modification} && $s->{fetch} && $s->{hook} ) {

      # no local modifications, fetch successful
      if ( $s->{originCommit} ) {

        # updates available
        send_as(
          JSON => {
            success => 2,
            message => "Updates available (" . $s->{originCommit} . ")"
          }
        );
      } else {

        # no updates
        send_as(
          JSON => {
            success => 1,
            message => "System UpToDate"
          }
        );
      } ## end else [ if ( $s->{originCommit...})]
    } elsif ( !$s->{fetch} ) {

      # connection to repository failed
      send_as(
        JSON => {
          success => 0,
          message => "Check failed"
        }
      );
    } elsif ( !$s->{hook} ) {

      # the hook file will not trigger restart
      send_as(
        JSON => {
          success => 0,
          message => "Hook not installed"
        }
      );
    } else {

      # local changes
      send_as(
        JSON => {
          success => 0,
          message => "Commit your local modifications"
        }
      );
    } ## end else [ if ( !$s->{modification...})]
  } elsif ( $status == 1 ) {

    # upgrade
    if ( $git->upgrade() ) {
      send_as(
        JSON => {
          success => 1,
          message => "Upgrade done!"
        }
      );
    } else {
      send_as(
        JSON => {
          success => 0,
          message => "Upgrade failed!"
        }
      );
    } ## end else [ if ( $git->upgrade() )]
  } else {

    # error
    send_as(
      JSON => {
        success => 0,
        message => "Unknown command!"
      }
    );
  } ## end else [ if ( $status == 0 ) ]
}; ## end cherryweb => sub

# working with the repo
post '/maintenance' => require_role cherryweb => sub {
  my $upload = request->upload('file');

  if ( !$upload ) {
    send_as(
      JSON => {
        success => 0,
        message => "Upload failed!",
      }
    );
  } ## end if ( !$upload )

  my $tempname = $upload->tempname;

  my $mtainer = cherryEpg::Maintainer->new();

  if ( $mtainer->load($tempname) ) {
    my $success = $mtainer->apply() // 0;
    my $output  = $mtainer->output;
    my $pod     = $mtainer->pod;

    send_as(
      JSON => {
        success => $success,
        message => "[" . $mtainer->name . "] applied",
        pod     => $pod,
        content => $output,
      }
    );
  } ## end if ( $mtainer->load($tempname...))

  send_as(
    JSON => {
      success => 0,
      message => "Loading failed!",
    }
  );
}; ## end cherryweb => sub

# read single log entry
get '/log/:id.json' => require_role cherryweb => sub {
  my $id = params->{id};

  my $cherry = cherryEpg->instance();

  my $row = $cherry->epg->getLogEntry($id);

  send_as( JSON => {} ) unless $row && $row->{info};

  delete $row->{info}{source}{blob}
      if $row
      && $row->{info}
      && ref( $row->{info} ) eq 'HASH'
      && $row->{info}{source}
      && $row->{info}{source} eq 'HASH'
      && $row->{info}{source}{blob};

  # manual conversion to JSON allows to have canonical format
  response_header( 'Content-Type' => 'application/json' );
  return JSON::XS->new->utf8->canonical(1)->encode( $row->{info} );
}; ## end cherryweb => sub

# default route
any qr{.*} => sub {
  status 'not_found';
  template '404', { path => request->path };
};

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
