function ServiceMatrix() {
  var count = 0;
  var day = 5;
  var cachedData = Array();
  var loading = 0;

  this.refresh = () => {
    if (loading) {
      return;
    }
    loading = 1;
    $("#eBudget").html("loading...");
    $.ajax({
      context: this,
      url: "/ebudget",
      dataType: 'json',
      data: 'day=' + day,
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      success: this.newdata,
      error: function(jqXHR, tStatus, err) {
        if (tStatus === 'parsererror') {
          $(location).attr("href", "/");
          return;
        }
        setPanelState('#dashBoard', 'danger');
        $("#serviceDash").html('<div class="alert alert-warning">Error getting analysis data. Please refresh!</div>');
        $("#eBudget").html("failed");
        count = 0;
        loading = 0;
      },
      timeout: 8000
    });
  };

  this.newdata = (report) => {
    loading = 0;
    if (report.status === 0) {
      setPanelState('#dashBoard', 'success');
    } else if (report.status === 1) {
      setPanelState('#dashBoard', 'warning');
    } else if (report.status === 3) {
      setPanelState('#dashBoard', 'danger');
      $("#eBudget").html(report.timestamp);
      $("#serviceDash").html('<div class="alert alert-warning" role="alert">Connecting to database failed. Please check service!</div>');
      count = 0;
      return;
    } else {
      setPanelState('#dashBoard', 'danger');
    }
    // is size of previous result is equal to current, just update data
    if (report.data.length === count) {
      this.update(report);
    } else {
      this.build(report);
    }
  };

  this.update = (report) => {
    $("#eBudget").html(report.timestamp);
    $.each(report.data, function(i, channel) {
      // define state based on budget
      var state = 'success';
      if (channel.status == 2) {
        state = 'danger';
      } else if (channel.status == 1) {
        state = 'warning';
      }
      $("#ch" + channel.id).removeClass().addClass(state);
      $("#ch" + channel.id + " time").timeago("update", channel.update);
      $("#ch" + channel.id + " span").sparkline(channel.budget, {
        type: 'bar',
        barColor: '#007fff',
        zeroColor: '#ff0000',
        negBarColor: '#0f95d4',
        tooltipSuffix: ' events'
      });
    });
  };

  this.build = (report) => {
    // clear the area
    $("#serviceDash").html("");
    // generate a matrix 6 columns width max and starting with 10 rows
    count = report.data.length;
    var maxCols = 6;
    var cols, rows, tail;

    if (count === 0) {
      return;
    }
    if (count < maxCols) {
      rows = 1;
      cols = count;
      tail = count;
    } else {
      tail = count % maxCols;
      rows = Math.ceil(count / maxCols);
      cols = maxCols;
    }

    for (var c = 0; c < cols; c++) {
      $("#serviceDash").append(
        `<div class="col-md-2">
          <div id="col${c}" class="panel panel-default">
            <table class="table table-condensed dashboard">
              <thead>
                <tr class="bg-primary"><th>Service</th><th>Buffer</th><th>Last</th></tr>
              </thead>
              <tbody></tbody>
            </table>
            </div>
          </div>`);
    }

    $.each(report.data, function(i, channel) {
      var col = parseInt(i / rows);
      if (col >= tail && tail !== 0) {
        col = parseInt((i - tail) / (rows - 1));
      }
      var column = $('#col' + col).find('tbody');

      column.append(
        `<tr id="ch${channel.id}">
            <td class="moreInfo">
              <a target="_xmltv" href="/export/${channel.id}.xml">${channel.name.substr(0, 9)}</a>
            </td>
            <td>
              <span class="sparkline">...</span>
            </td>
            <td><time class="timeago"></time></td>
          </tr>`);
    });

    this.update(report);

    $('time.timeago').timeago();
    $('.moreInfo').tooltip({
      title: this.hData,
      html: true,
      animation: true,
      placement: 'auto',
      container: 'body',
    });
  };

  this.hData = () => {
    return; // TODO

    var id = $(this).parent().attr('id').substring(2);;

    if (id in cachedData) {
      return cachedData[id];
    }

    var info;
    $.ajax({
      context: this,
      url: "/channel",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      success: function(data) {
        info = data.channel_id + ' ' + data.parser;
        cachedData[id] = info;
      },
      data: 'id=' + id,
      error: function() {

      },
      timeout: 4000
    });

    return info;
  };

  this.refresh();
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function LogBrowser(large) {
  var levels = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'];

  this.readFilterButton = () => {
    var filter = [];
    for (var i = 0; i < 5; i++) {
      var b = '#logBrowser-' + i;
      if ($(b).hasClass('active')) {
        filter.push(i);
      }
    }
    return filter.join();
  };

  if (large) {
    $('#logBrowserSlider').slider({
      min: 0,
      max: 5,
      value: 2,
      natural_arrow_keys: true,
      step: 1,
      orientation: 'horizontal',
      tooltip: 'show',
      formatter: function(value) {
        return levels[value];
      },
      handle: 'round'
    });

    $('#logBrowserSlider').on('change', (ev) => {
      $("#logBrowserMinLevel").text(levels[ev.value.newValue]);
      this.table.draw();
    });

    $("#logBrowserMinLevel").text(levels[logBrowserSlider.value]);

    $('#logBrowser .btn').click((e) => {
      $(e.currentTarget).toggleClass("active");
      this.table.draw();
      return false;
    });
  }

  this.table = $('#logTable').DataTable({
    serverSide: true,
    columns: [{
        "width": "5px",
        "targets": 0,
        "data": null,
        "defaultContent": ""
      },
      {
        "data": "timestamp",
        "width": "43px"
      },
      {
        "data": "category",
        "width": "13px"
      },
      {
        "data": "level",
        "width": "14px"
      },
      {
        "data": "text",
        "width": "175px"
      },
      {
        "data": "channel",
        "width": "20px"
      },
      {
        "data": "eit_id",
        "width": "20px"
      }
    ],
    autoWidth: false,
    processing: false,
    ordering: false,
    searching: false,
    ajax: {
      url: "/log",
      type: "POST",
      data: (d) => {
        if (large) {
          d.category = this.readFilterButton();
          d.level = logBrowserSlider.value;
        } else {
          d.category = '';
          d.level = 3;
        }
      },
      complete: (settings, json) => {
        if (json === 'success') {
          $("#logUpdate").html(settings.responseJSON.timestamp);
        }
      },
      error: () => {
        $("#logUpdate").html("failed");
      }
    },
    scrollY: large ? 600 : 300,
    scroller: {
      loadingIndicator: true,
    },
    fnRowCallback: (nRow, aData, iDisplayIndex, iDisplayIndexFull) => {
      switch (aData.level) {
        case 'fatal':
        case 'error':
          $(nRow).removeClass().addClass('danger');
          break;
        case 'warn':
          $(nRow).removeClass().addClass('warning');
          break;
        case 'info':
          $(nRow).removeClass().addClass('success');
          break;
        case 'trace':
        case 'debug':
          $(nRow).removeClass().addClass('active');
          break;
        default:
          $(nRow).removeClass().addClass('info');
      }

      if (aData.hasinfo == 1) {
        $(nRow).find('td:first').addClass('details-control');
      }
    }
  });

  this.details = (id, tr) => {
    $.ajax({
      context: this,
      url: "/log/" + id + ".json",
      dataType: 'json',
      type: 'GET',
      success: function(data) {
        if (data !== '') {
          var row = this.table.row(tr);
          var $pre = $(`<a href="/log/${id}.json"><span class="label label-primary">JSON <i class="glyphicon glyphicon-file"></i></span></a>`);
          var $view = $('<span></span>').jsonViewer(data, {
            collapsed: true,
            rootCollapsable: false
          });
          row.child($pre, 'even').show();
          $pre.after($view);
          $view.children().children().children('a.json-toggle').click();
          tr.addClass('shown');
        }
      },
      timeout: 4000
    });

    return;
  };

  this.hide = () => {
    $('#logBrowser').addClass('hidden');
  };

  this.refresh = () => {
    this.table.draw();
  };

  $('#logTable tbody').on('click', 'td.details-control', (e) => {
    var $tr = $(e.currentTarget).closest('tr');
    var row = this.table.row($tr[0]);

    if (row.child.isShown()) {
      // This row is already open - close it
      row.child.hide();
      $tr.removeClass('shown');
    } else {
      // Open this row
      this.details(row.data().id, $tr);
    }
  });

}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function RingelSpiel() {
  var count = 0;
  var loading = 0;

  this.refresh = () => {
    if (loading) {
      return;
    }
    loading = 1;
    $("#oStreams").html("loading...");
    $("#oStats").html("");
    $.ajax({
      context: this,
      url: "/carousel",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      success: this.newdata,
      error: function(jqXHR, tStatus, err) {
        if (tStatus === 'parsererror') {
          $(location).attr("href", "/ringelspiel");
          return;
        }
        setPanelState('#ringelSpiel', 'danger');
        $("#oStreams").html("failed");
        $("#streamDash").html('<div class="alert alert-warning" role="alert">Error getting analysis data. Please refresh!</div>');
        count = 0;
        loading = 0;
      },
      timeout: 4000
    });
  };

  this.update = (report) => {
    var status = '<time class="timeago" datetime="' + report.start + '"></time>' + (report.timing.overshootProtection ? ' protected' : '');
    $("#oStats").html(status);
    if (report.exceed) {
      $("#oPublic").html("Public release - bitrate exceeded");
    }
    if (report.trialend) {
      $("#oPublic").html("Trial period has ended");
    }
    // reference for bargraph is 1Mbps or the higher
    var maxBitrate = 1000000;
    $.each(report.streams, function(i, stream) {
      maxBitrate = Math.max(stream.bitrate, maxBitrate);
    });
    maxBitrate = Math.ceil(maxBitrate / 1000000) * 10000;
    $.each(report.streams, function(i, stream) {
      var bar = stream.bitrate / maxBitrate;
      var block = '<div class="container-fluid"><a data-toggle="collapse" data-parent="#streamAccordion" href="#chunkList' + i + '"><div class="row">' + '<div class="col-md-4"><h4 class="panel-title"><i class="glyphicon glyphicon glyphicon-tag"></i> udp://' + stream.addr + ':' + stream.port + '</h4></div>' + '<div class="col-md-4">' + '<div class="progress"> <div class="progress-bar progress-bar-warning" role="progressbar" aria-valuenow="' + bar + '" aria-valuemin="0" aria-valuemax="100" style="width: ' + bar + '%"></div> </div>' + '</div>' + '<div class="col-md-2 text-right">' + stream.bitrate.toLocaleString() + ' bps</div>' + '<div class="col-md-1 text-right"><span class="sparkline">...</span><i class="glyphicon glyphicon glyphicon-time"></i><i class="glyphicon glyphicon-time glyphicon-hourglass"></i></div>' + '<div class="col-md-1 text-right"><time class="timeago" datetime="' + stream.last + '"></time></div></a></div></div>';
      $('#stream' + i).html(block);

      $.each(stream.files, function(j, file) {
        block = '<div class="col-md-2 bg-info">' + (file.title.trim() ? file.title : '<i>-</i>') + '</div>' + '<div class="col-md-2 text-right">' + file.file + '</div>' + '<div class="col-md-2 text-right">' + file.size + ' pkt</div>' + '<div class="col-md-2 text-right">&nbsp;</div>' + '<div class="col-md-2 text-right bg-info">' + file.bitrate.toLocaleString() + ' bps</div>' + '<div class="col-md-1 text-right">&nbsp;</div>' + '<div class="col-md-1 text-right"><time class="timeago" datetime="' + file.last + '"></time></div>';
        $('#st' + i + 'file' + j).html(block);
      });

    });
    $('time.timeago').timeago();
  };

  this.newdata = (report) => {
    loading = 0;
    $("#oStreams").html(report.timestamp);
    if (report.error) {
      setPanelState('#ringelSpiel', 'danger');
      $("#streamDash").html('<div class="alert alert-warning" role="alert">Playout not responding. Please check service!</div>');
      count = 0;
      return;
    }
    setPanelState('#ringelSpiel', 'success');
    // is count of previous streams is equal to current, just update data
    if (report.streams.length === count) {
      this.update(report);
    } else {
      this.build(report);
    }
    count = report.streams.length;
  };

  this.build = (report) => {
    // clear the area
    $("#streamDash").html('<div class="panel-group" id="streamAccordion"></div>');
    $.each(report.streams, function(i, stream) {
      // reference for bargraph is 10Mbps
      var bar = stream.bitrate / 100000;
      if (bar > 100) {
        bar = 100;
      }
      var block = `<div class="panel panel-primary"><div id="stream${i}" class="panel-heading multicast"></div>
      <div id="chunkList${i}" class="panel-collapse collapse chunkGroup"><div class="container-fluid">
      <div class="row bg-info"><div class="col-md-2 text-center">Description</div><div class="col-md-2 text-center">Filename</div>
      <div class="col-md-2 text-center">Filesize</div><div class="col-md-2 text-center">&nbsp;</div><div class="col-md-2 text-center">Bitrate</div>
      <div class="col-md-1 text-center">Flags</div><div class="col-md-1 text-center">Last</div></div>`;
      $.each(stream.files, function(j, file) {
        block += '<div id="st' + i + 'file' + j + '" class="row"></div>';
      });
      block += '</div></div>';
      block += '</div>';
      $('#streamAccordion').append(block);
    });
    this.update(report);
  };

  this.refresh();
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function SystemInfo() {
  this.refresh = () => {
    $("#systemStatus").html("loading...");
    $("#systemUptime").addClass('hidden');
    $.ajax({
      context: this,
      url: "/status",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      success: this.update,
      error: function(jqXHR, tStatus, err) {
        if (tStatus === 'parsererror') {
          $(location).attr("href", "/system");
          return;
        }
        $("#systemStatus").html("Failed. Please reload!");
        $("#systemStatus").removeClass("label-default").addClass("label-danger");
        $("#systemVersion").html('');
        $("#systemEPG").html('');
        $("#systemPlayout").html('');
        $("#systemNTP").html('');
        $("#systemDatabase").html('');
        $("#systemWebgrab").html('');
        $("#systemAnnouncer").html('');
      },
      timeout: 100000
    });
  };

  this.update = (report) => {
    $("#systemStatus").removeClass('label-danger').addClass('label-default');
    $("#systemStatus").html(report.timestamp);
    $("#systemUptime time").timeago('update', report.systemStart);
    $("#systemUptime").removeClass('hidden').addClass('label-info');
    $('time.timeago').timeago();

    var block = "";
    $.each(Object.keys(report.version).sort(), function(i, key) {
      var no = report.version[key];
      if (no === null) {
        no = '-';
      }
      block += '<span class="label label-primary">' + key + ': ' + no + "</span>\n";
    });
    $("#systemVersion").html(block);
    $("#systemEPG").html(this.generateBlock(report.modules.epg, true));
    $("#systemPlayout").html(this.generateBlock(report.modules.playout));
    $("#systemNTP").html(this.generateBlock(report.modules.ntp));
    $("#systemDatabase").html(this.generateBlock(report.modules.database));
    if (report.modules.webgrab) {
      $("#systemWebgrab").html(this.generateBlock(report.modules.webgrab, true));
      $("#systemWebgrab").parent().removeClass('hidden');
    } else {
      $("#systemWebgrab").parent().addClass('hidden');
    }
    if (report.modules.announcer) {
      $("#systemAnnouncer").html(this.generateBlock(report.modules.announcer, false));
      $("#systemAnnouncer").parent().removeClass('hidden');
    } else {
      $("#systemAnnouncer").parent().addClass('hidden');
    }
    $('[data-toggle="tooltip"]').tooltip({
      html: true,
      placement: 'right'
    });
  };

  this.generateBlock = (data, skipDetails) => {
    var block = '<a href="#" data-toggle="tooltip" title="';
    if (skipDetails !== true) {
      $.each(Object.keys(data.report).sort(), function(i, key) {
        var x = data.report[key];
        block += key + ': ' + x + '<br/>';
      });
    }
    block += '">';
    block += '<span class="label ' + (data.status === 0 ? 'label-success' : (data.status === 1 ? 'label-warning' : 'label-danger')) + '">' + data.msg + '</span>';
    block += '</a>';
    return block;
  };

  $('time.timeago').timeago();
  $('[data-toggle="tooltip"]').tooltip({
    html: true,
    placement: 'right'
  });

  this.refresh();
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function setPanelState(id, state) {
  $.each(['danger', 'default', 'success', 'warning'], function(index, value) {
    if (value === state) {
      $(id).addClass('panel-' + state);
    } else {
      $(id).removeClass('panel-' + value);
    }
  });
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function Timer(fn) {
  var interval = 60000;
  var timerObj = setInterval(fn, interval);

  this.stop = () => {
    if (timerObj) {
      clearInterval(timerObj);
      timerObj = null;
    }
    return this;
  };

  // start timer using current settings (if it's not already running)
  this.start = () => {
    if (!timerObj) {
      this.stop();
      timerObj = setInterval(fn, interval);
    }
    return this;
  };

  // start with new interval, stop current interval
  this.reset = () => {
    return this.stop().start();
  };

  // start the function and reset interval
  this.now = () => {
    this.stop();
    fn();
    this.start();
  };
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function ConfigPanel() {

  this.init = () => {
    $('#cPanel').removeClass('hidden');
    $('#sourceFileShow').val('');
    const $template = $('#browseForm tr.scheme').remove().first();
    $template.removeClass('hidden');
    this.browseTemplate = $template;
    this.refresh();
    $('#wMenuBrowse').trigger('click');
  };

  this.refresh = () => {
    $.ajax({
      url: "/setup",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      timeout: 5000
    }).done((data) => {
      $('#filename').html(data.filename);
      $('#channel').html(data.channel);
      $('#eit').html(data.eit);
      $('#rule').html(data.rule);
      $("#date").html(data.timestamp);
    }).fail(() => {
      $('#filename').html('???????????????????');
    });
  };

  this.browse = () => {
    $('#manageForm').addClass('hidden');
    $('#configWizard').addClass('hidden');
    $('#uploadForm').addClass('hidden');
    $('#validateForm').addClass('hidden');
    $('#activateForm').addClass('hidden');
    $('#browseForm').removeClass('hidden');

    $('#browseReport table tr.scheme').remove();

    $.ajax({
      url: "/setup/browse",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      timeout: 5000
    }).done((data) => {
      if (data.length) {
        data.forEach((item) => {
          const $row = this.browseTemplate.clone();
          $row.find('td:nth-child(1)').html('<time class="timeago" datetime="' + item.timestamp + '">' + item.timestamp + '</time>&nbsp;<span class="hidden">' + item.timestamp + '</span>');
          $row.find('td:nth-child(2)').html(item.description + ' <b>' + item.channel + '/' + item.eit + '/' + item.rule);
          $row.find('td:nth-child(3)').html(item.source);
          $row.find('a').attr('href', 'scheme/' + item.filename);
          $row.data('filename', item.filename);
          $('#browseReport table').append($row);
        });
        $('time.timeago').timeago();
      } else {}
    });
  };

  this.delete = (filename) => {
    $.ajax({
      url: "/setup/delete",
      dataType: 'json',
      type: 'POST',
      data: {
        filename: filename
      },
      timeout: 2000
    }).done((data) => {
      if (data.success && data.filename === filename) {
        var row = $('tr').filter((index, item) => {
          return $(item).data('filename') === filename;
        });
        $(row).find('td').animate({
          opacity: '0.0'
        }, 'slow', () => {
          $(row).remove();
        });
      } else {

      }
    });
  };

  this.download = (filename) => {
    $.ajax({
      url: "/setup/delete",
      dataType: 'json',
      type: 'POST',
      data: {
        filename: filename
      },
      timeout: 2000
    }).done((data) => {
      if (data.success && data.filename === filename) {
        var row = $('tr').filter((index, item) => {
          return $(item).data('filename') === filename;
        });
        $(row).find('td').animate({
          opacity: '0.0'
        }, 'slow', () => {
          $(row).remove();
        });
      } else {

      }
    });
  };

  this.prepare = (filename) => {
    $.ajax({
      url: "/setup/prepare",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      data: {
        filename: this.filename
      },
      timeout: 5000
    }).done((data) => {
      if (data.success) {
        this.mtime = data.mtime;
        $('#browseForm').addClass('hidden');
        $('#configWizard').removeClass('hidden');
        $('#activateForm div.form-group').last().removeClass('hidden');
        $('#activateForm div.alert-warning').addClass('hidden');
        $('#activateForm div.alert-success').addClass('hidden');
        $('#activateForm div.alert-danger').addClass('hidden');
        $('#activateForm h3').html(data.description);
        $('#activateForm input').prop('disabled', false);
        $('#import').prop('disabled', true);
        $('#step1').removeClass('active');
        $('#step2').removeClass('active');
        $('#step3').addClass('active');
        $('#activateForm').removeClass('hidden');
        $('#validateForm').addClass('hidden');
      } else {
        $('#formFailed').modal('show');
      }
    }).fail(() => {
      $('#formFailed').modal('show');
    });
  };

  $('#browseReport').on('click', 'td:nth-child(1),th:nth-child(1)', (e) => {
    $('#browseReport td:nth-child(1)>time').toggleClass('hidden');
    $('#browseReport td:nth-child(1)>span').toggleClass('hidden');
  });

  $('#browseReport').on('click', 'button', (e) => {
    var button = $(e.currentTarget).attr('name');
    this.filename = $(e.currentTarget).closest('tr').data('filename');

    if (button === 'del') {
      $('#formConfirm').modal('show');
    } else if (button === 'act') {
      this.prepare(this.filename);
    }
  });

  $('#btnConfirm').on('click', (e) => {
    $('#formConfirm').modal('hide');
    this.delete(this.filename);
  });

  $('#addFileForm button[name=upload]').on('click', (event) => {
    if (!$('#addFileForm').valid()) {
      return;
    }
    var formData = new FormData();
    var file = $('#sourceFile')[0].files[0];
    formData.append('file', file);
    $('#parseReport').empty();
    $('#parseReport').append('<p class="text-danger"><i class="glyphicon glyphicon-hourglass"></i> <b>Waiting for validation!</b></p>');

    $('#step1').removeClass('active');
    $('#step2').addClass('active');
    $('#uploadForm').addClass('hidden');
    $('#validateForm').removeClass('hidden');
    $('#validateForm input[name=description]').val('');
    $('#validateForm button[name=continue]').prop('disabled', true);
    $('#validateForm input[name=description]').prop('disabled', true);
    $('.commands span').addClass('hidden');

    $.ajax({
      url: "/setup/upload",
      dataType: 'json',
      data: formData,
      type: 'POST',
      processData: false,
      mimeTypes: 'multipart/form-data',
      contentType: false,
      cache: false,
      timeout: 10000
    }).always((data) => {
      var validScheme = false;
      if (data.error) {
        $('#parseReport').empty();
        $('#parseReport').append('<p class="text-primary"><i class="glyphicon glyphicon-file"></i> Source file: <b>' + data.filename + '</b></p>');
        if (data.error.length) {
          data.error.forEach((item) => {
            var msg = item.replace(/(\[.+\])/, '<b>$1</b>');
            $('#parseReport').append('<p class="text-danger"><i class="glyphicon glyphicon-alert"></i> ' + msg + '</p>');
          });
        } else {
          validScheme = true;
        }
        $('#parseReport').append('<p class="text-primary"><i class="glyphicon glyphicon-film"></i> Services: <b>' + data.channel + '</b></p>');
        $('#parseReport').append('<p class="text-primary"><i class="glyphicon glyphicon-transfer"></i> EIT: <b>' + data.eit + '</b></p>');
        $('#parseReport').append('<p class="text-primary"><i class="glyphicon glyphicon-th-list"></i> Rules: <b>' + data.rule + '</b></p>');
        if (validScheme) {
          $('#parseReport').append('<p class="bg-success"><i class="glyphicon glyphicon-ok"></i><b> Scheme valid.</b></p>');
          // session check
          this.mtime = data.mtime;
        } else {
          $('#parseReport').append('<p class="bg-danger"><i class="glyphicon glyphicon-remove"></i><b> Scheme not valid. Fix errors and try again!</b></p>');
          this.mtime = null;
        }
      } else {
        $('#parseReport').append('<p class="bg-danger">No response from server. Please retry!</p>');
      }
      $('#validateForm button[name=continue]').prop('disabled', !validScheme);
      $('#validateForm input[name=description]').prop('disabled', !validScheme);
    });
    return;
  });

  $('#wMenuUpload').on('click', (event) => {
    $('#manageForm').addClass('hidden');
    $('#step1').addClass('active');
    $('#configWizard').removeClass('hidden');
    $('#step2').removeClass('active');
    $('#step3').removeClass('active');
    $('#uploadForm').removeClass('hidden');
    $('#validateForm').addClass('hidden');
    $('#activateForm').addClass('hidden');
    $('#browseForm').addClass('hidden');
    $('#sourceFileShow').val('');
  });

  $('#validateForm button[name=upload]').on('click', (event) => {
    $('#wMenuUpload').click();
  });

  $('#step1').on('click', (event) => {
    $('#wMenuUpload').click();
  });

  $('#wMenuRestore').on('click', (event) => {
    $('#configWizard').addClass('hidden');
    $('#uploadForm').addClass('hidden');
    $('#validateForm').addClass('hidden');
    $('#activateForm').addClass('hidden');
    $('#browseForm').addClass('hidden');
    $('#manageForm').removeClass('hidden');
  });

  $('#wMenuBrowse').on('click', (event) => {
    this.browse();
  });

  $('#wMenuActive').on('click', (event) => {
    $('#configWizard').addClass('hidden');
    $('#uploadForm').addClass('hidden');
    $('#validateForm').addClass('hidden');
    $('#activateForm').addClass('hidden');
  });

  $('#validateForm button[name=continue]').on('click', (event) => {
    if (!$('#validateForm form').valid()) {
      return;
    }
    var data = {
      description: $('#validateForm input[name=description]').val(),
      mtime: this.mtime
    };
    $.ajax({
      url: "/setup/validate",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      data: data,
      timeout: 5000
    }).done((data) => {
      if (data.success) {
        $('#activateForm div.form-group').last().removeClass('hidden');
        $('#activateForm div.alert-warning').addClass('hidden');
        $('#activateForm div.alert-success').addClass('hidden');
        $('#activateForm div.alert-danger').addClass('hidden');
        $('#activateForm h3').html(data.description);
        $('#activateForm input').prop('disabled', false);
        $('#import').prop('disabled', true);
        $('#step2').removeClass('active');
        $('#step3').addClass('active');
        $('#activateForm').removeClass('hidden');
        $('#validateForm').addClass('hidden');
      } else {
        $('.commands span').html('Failed to continue with activation').removeClass('hidden');
      }
    });
  });

  $('#activateForm button[name=activate]').on('click', (event) => {
    var data = {};
    $.each($('#activateForm input'), (i, check) => {
      data[check.id] = $(check).is(':checked') ? 1 : 0;
    });
    data.mtime = this.mtime;

    $('#activateForm div.form-group').last().addClass('hidden');
    $('#activateForm input').prop('disabled', true);
    $('#activateForm div.alert-warning').removeClass('hidden');
    $('#activateForm div.alert-success').addClass('hidden');
    $('#activateForm div.alert-danger').addClass('hidden');

    $.ajax({
      url: "/setup/activate",
      dataType: 'json',
      type: 'POST',
      data: data,
      timeout: 120000
    }).done((data) => {
      if (data.import) {
        this.refresh();
        $('#activateForm div.alert-warning').addClass('hidden');
        $('#activateForm div.alert-success').removeClass('hidden');
        $('#activateForm div.alert-danger').addClass('hidden');
      } else {
        $('#activateForm div.alert-warning').addClass('hidden');
        $('#activateForm div.alert-success').addClass('hidden');
        $('#activateForm div.alert-danger').removeClass('hidden');
      }
    });
  });

  $('#sourceFile').change((event) => {
    var fileName = $(event.currentTarget).val();
    $('#sourceFileShow').val(fileName);
  });

  $("#validateForm form").validate({
    debug: true,
    rules: {
      description: {
        required: true,
        minlength: 5,
      }
    },
    messages: {
      description: {
        required: "Short scheme description is required",
        minlength: jQuery.validator.format('Description needs to have at least {0} characters'),
      }
    },
    highlight: function(element) {
      $(element).closest('.form-group').addClass('has-error');
    },
    success: function(element) {
      element.closest('.form-group').removeClass('has-error');
    },
    errorElement: 'span',
    errorClass: 'help-block',
    errorPlacement: function(error, element) {
      error.insertAfter(element.parent());
    }
  });

  $("#addFileForm").validate({
    debug: true,
    rules: {
      sourceFileShow: {
        required: true,
        extension: "xls"
      }
    },
    messages: {
      sourceFileShow: {
        required: "Input data file is required",
        extension: "Only xls files are accepted"
      }
    },
    highlight: function(element) {
      $(element).closest('.form-group').addClass('has-error');
    },
    success: function(element) {
      element.closest('.form-group').removeClass('has-error');
    },
    errorElement: 'span',
    errorClass: 'help-block',
    errorPlacement: function(error, element) {
      error.insertAfter(element.parent());
    }
  });
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function Announcement() {
  this.init = () => {
    this.refresh();
  };

  this.update = () => {
    if (this.data.success) {
      $('#present').prop('checked', this.data.announce.present.publish);
      $('#aPanel input[name=present]').val(this.data.announce.present.text);
      $('#following').prop('checked', this.data.announce.following.publish);
      $('#aPanel input[name=following]').val(this.data.announce.following.text);
      $('#aPanel input,button').attr('disabled', false);
    } else {
      $('#present').prop('checked', false);
      $('#aPanel input[name=present]').val("");
      $('#following').prop('checked', false);
      $('#aPanel input[name=following]').val("");
      $('#aPanel').attr('disabled', true);
    }
  };

  this.refresh = () => {
    $.ajax({
      url: "/announce",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      timeout: 5000
    }).done((data) => {
      this.data = data;
      this.update();
    }).fail(() => {
      $('#aPanel').attr('disabled', true);
    });
  };

  $('#aPanel button[name=save]').on('click', (event) => {
    var data = $('#aPanel form').serialize();

    $('#aPanel div.alert-warning').removeClass('hidden');
    $('#aPanel div.alert-success').addClass('hidden');
    $('#aPanel div.alert-danger').addClass('hidden');

    $.ajax({
      url: "/announce",
      dataType: 'json',
      type: 'POST',
      data: data,
      timeout: 5000
    }).done((data) => {
      if (data.success) {
        $('#aPanel div.alert-warning').addClass('hidden');
        $('#aPanel div.alert-success').removeClass('hidden');
        this.data = data;
        this.update();
      } else {
        $('#aPanel div.alert-warning').addClass('hidden');
        $('#aPanel div.alert-danger').removeClass('hidden');
      }
    }).fail(() => {
      $('#aPanel div.alert-warning').addClass('hidden');
      $('#aPanel div.alert-danger').removeClass('hidden');
    });
  });
}