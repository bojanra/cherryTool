function ServiceMatrix(log) {
  var count = 0;
  var loading = 0;
  var currentService = null;
  var logBrowser = log;

  this.build = (report) => {
    // clean the area
    $('#serviceDash').html('');
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
      $('#serviceDash').append(
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

      var $tr = $(`<tr id="ch${channel.id}">
            <td>${channel.name.substr(0, 9)}</td>
            <td><span class="sparkline">...</span></td>
            <td><time class="timeago"></time></td>
          </tr>`);
      $tr.data('id', channel.id);
      column.append($tr);
    });

    this.update(report);

    $('time.timeago').timeago();
  };

  this.ingest = (param) => {
    param.append('id', currentService);
    $('#serviceStatus').removeClass('hidden label-success label-danger').addClass('label-info').html('Uploading...');

    $.ajax({
      url: "/service/ingest",
      dataType: 'json',
      data: param,
      type: 'POST',
      processData: false,
      mimeTypes: 'multipart/form-data',
      contentType: false,
      cache: false,
      timeout: 10000
    }).always((item) => {
      if (item) {
        if (item.success) {
          $('#serviceStatus').removeClass('hidden label-info label-danger').addClass('label-success').html(item.message);
        } else {
          $('#serviceStatus').removeClass('hidden label-info label-success').addClass('label-danger').html(item.message);
        }
        $('#eBudget').click();
      } else {
        $('#serviceStatus').removeClass('hidden label-info label-success').addClass('label-danger').html('Upload failed');
      }
    });
  };

  this.present = (report) => {
    loading = 0;
    if (report.status === 0) {
      setPanelState('#dashBoard', 'success');
    } else if (report.status === 1) {
      setPanelState('#dashBoard', 'warning');
    } else if (report.status === 3) {
      setPanelState('#dashBoard', 'danger');
      $('#eBudget').html(report.timestamp);
      $('#serviceDash').html('<div class="alert alert-warning" role="alert">Connecting to database failed. Please check service!</div>');
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

  this.refresh = () => {
    if (loading) {
      return;
    }
    loading = 1;
    $('#eBudget').html('loading...');
    $.ajax({
      context: this,
      url: "/ebudget",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      success: this.present,
      error: function(jqXHR, tStatus, err) {
        if (tStatus === 'parsererror') {
          $(location).attr("href", "/");
          return;
        }
        setPanelState('#dashBoard', 'danger');
        $('#serviceDash').html('<div class="alert alert-warning">Error getting analysis data. Please refresh!</div>');
        $('#eBudget').html('failed');
        count = 0;
        loading = 0;
      },
      timeout: 8000
    });
  };

  this.showService = (data) => {
    if ('name' in data) {
      $('#serviceStatus').addClass('hidden');
      $('#serviceAgent ul').css('opacity', '1');
      $('#serviceAgent button').prop('disabled', false);
      $('#serviceName').html(data.name);
      $('#serviceId').html(data.channel_id);
      $('#serviceCodepage').html(data.codepage);
      $('#serviceLanguage').html(data.language);
      $('#serviceSegments').html(data.maxsegments);
      $('#serviceUpdate').html(data.grabber.update);
      $('#serviceParser').html(data.parser);
      $('#serviceUrl').val(data.grabber.url);
      $('#exportXML').prop('href', '/export/' + data.channel_id + '.xml');
      $('#exportXML').prop('target', '_' + data.channel_id);
      $('#exportCSV').prop('href', '/export/' + data.channel_id + '.csv');
      $('#exportCSV').prop('target', '_' + data.channel_id);
      $('#exportALL').prop('href', '/export/all.xml');
      $('#exportALL').prop('target', '_all');

      data.events.forEach((e, i) => {
        var $eventField = $('#event li').eq(i);
        $eventField.find('.start').html(e.timeSpan);
        $eventField.find('.title').html(e.title);
        $eventField.find('.subtitle').html(e.subtitle);
      });
    } else {
      $('#serviceStatus').removeClass('hidden label-success label-info').addClass('label-danger').html('failed');
      $('#serviceAgent ul').css('opacity', '.5');
      $('#serviceAgent button').prop('disabled', true);
      $('#serviceAgent a').removeAttr('href');
    }
  };

  this.update = (report) => {
    $('#eBudget').html(report.timestamp);
    $.each(report.data, function(i, channel) {
      // define state based on budget
      var state = 'success';
      if (channel.status === 2) {
        state = 'danger';
      } else if (channel.status === 1) {
        state = 'warning';
      }
      $('#ch' + channel.id).removeClass().addClass(state);
      $('#ch' + channel.id + " time").timeago('update', channel.update);
      $('#ch' + channel.id + " span").sparkline(channel.budget, {
        type: 'bar',
        barColor: '#007fff',
        zeroColor: '#ff0000',
        negBarColor: '#0f95d4',
        tooltipSuffix: ' events'
      });
    });
  };

  this.updateService = (id) => {
    if (currentService === id) {
      currentService = null;
      (logBrowser).setService(null);
      $('#serviceAgent').addClass('hidden');
      return;
    }
    currentService = id;
    (logBrowser).setService(id);

    // show agent
    $('#serviceAgent').removeClass('hidden');

    $.ajax({
      context: this,
      url: "/service/info",
      dataType: 'json',
      data: 'id=' + id,
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      timeout: 3000
    }).always(this.showService);
  };

  $('#serviceDash').on('click', 'tr', (event) => {
    var $tr = $(event.currentTarget);
    this.updateService($tr.data('id'));
  });

  $('#serviceClose').on('click', () => {
    this.currentService = null;
    (logBrowser).setService(null);
    $('#serviceAgent').addClass('hidden');
  });

  $('#ingestData button').on('click', () => {
    $('#eventFile').click();
  });

  $('#eventFile').on('change', () => {
    var formData = new FormData();
    var file = $('#eventFile')[0].files[0];
    formData.append('file', file);

    this.ingest(formData);
  });

  $('html').on('dragover', (event) => {
    event.preventDefault();
    event.stopPropagation();
  });

  $('.upload-area').on('drop', (event) => {
    event.preventDefault();
    event.stopPropagation();

    var formData = new FormData();
    formData.append('file', event.originalEvent.dataTransfer.files[0]);

    this.ingest(formData);
  });

  this.refresh();
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function LogBrowser(large) {
  var levels = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'];
  var currentService = null;

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

  this.setService = (id) => {
    if (id == null) {
      $('#logService').addClass('hidden');
    } else {
      $('#logService').removeClass('hidden');
    }
    this.currentService = id;
    this.refresh();
  }

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

    $('#logBrowserSlider').on('change', (event) => {
      $('#logBrowserMinLevel').text(levels[event.value.newValue]);
      this.table.draw();
    });

    $('#logBrowserMinLevel').text(levels[logBrowserSlider.value]);

    $('#logBrowser .btn').click((event) => {
      $(event.currentTarget).toggleClass('active');
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
          d.level = 0;
        }
        d.channel = this.currentService;
      },
      complete: (settings, json) => {
        if (json === 'success') {
          $('#logUpdate').html(settings.responseJSON.timestamp);
        }
      },
      error: () => {
        $('#logUpdate').html('failed');
      }
    },
    scrollY: large ? (window.innerHeight - 239) : 300,
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

  $('#logTable tbody').on('click', 'td.details-control', (event) => {
    var $tr = $(event.currentTarget).closest('tr');
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

  $(window).on('resize', () => {
    $('.dataTables_scrollBody').css('height', window.innerHeight - 239);
    this.table.draw();
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
    $('#oStreams').html('loading...');
    $('#oLast').html('');
    $('#oStats').html('');
    $.ajax({
      context: this,
      url: "/carousel",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      success: this.newdata,
      error: function(jqXHR, tStatus, err) {
        if (tStatus === 'parsererror') {
          $(location).attr('href', '/ringelspiel');
          return;
        }
        setPanelState('#ringelSpiel', 'danger');
        $('#oStreams').html('failed');
        $('#streamDash').html('<div class="alert alert-warning" role="alert">Error getting analysis data. Please refresh!</div>');
        count = 0;
        loading = 0;
      },
      timeout: 4000
    });
  };

  this.update = (report) => {
    var status = '<time class="timeago" datetime="' + report.start + '"></time>' + (report.timing.overshootProtection ? ' protected' : '');
    $('#oLast').html(status);
    if (report.status == 0) {
      $('#oStats').removeClass('label-danger').addClass('label-success');
    } else if (report.status == 1) {
      $('#oStats').addClass('label-danger').removeClass('label-success');
    }
    $('#oStats').html(report.message);
    // reference for bargraph is 1Mbps or the higher
    var maxBitrate = 1000000;
    $.each(report.streams, function(i, stream) {
      maxBitrate = Math.max(stream.bitrate, maxBitrate);
    });
    maxBitrate = Math.ceil(maxBitrate / 1000000) * 10000;
    $.each(report.streams, function(i, stream) {
      var bar = stream.bitrate / maxBitrate;
      var tdtOffset = '';
      if ('tdt' in stream && (stream.tdt > 1 || stream.tdt < 0)) {
        tdtOffset = `<span class="badge">${stream.tdt > 1 ? '+' : '-'}${stream.tdt-1}</span>`;
      }
      var block = `<div class="container-fluid"><a data-toggle="collapse" data-parent="#streamAccordion" href="#chunkList${i}">
      <div class="row"><div class="col-md-4">
      <h4 class="panel-title"><i class="glyphicon glyphicon glyphicon-tag"></i> udp://${stream.addr}:${stream.port}</h4></div>
      <div class="col-md-4">
        <div class="progress"> <div class="progress-bar progress-bar-info" role="progressbar" aria-valuenow="${bar}" aria-valuemin="0" aria-valuemax="100" style="width: ${bar}%"></div></div>
      </div>
      <div class="col-md-1 text-right">${tdtOffset}&nbsp;${stream.tdt ? '<i class="glyphicon glyphicon glyphicon-calendar"></i>' : ''}
      ${ stream.pcr ? '<i class="glyphicon glyphicon-time glyphicon-time"></i>' : ''}</div>
      <div class="col-md-2 text-right">${stream.bitrate} bps</div>
      <div class="col-md-1 text-right"><time class="timeago" datetime="${stream.last}"></time></div></a></div></div>`;

      $('#stream' + i).html(block);

      $.each(stream.files, function(j, file) {
        var flags = `${file.tdt ? '<i class="glyphicon glyphicon glyphicon-calendar"></i>' : ''}${ file.pcr ? '<i class="glyphicon glyphicon-time glyphicon-time"></i>' : ''}`;
        block = `<div class="col-md-6">${file.title.trim() ? file.title : '<i>-</i>'}</div>
          <div class="col-md-1 text-right">${'pid' in file ? flags+' '+file.pid : '?'}</div>
          <div class="col-md-2 text-right">${file.size} pkt</div>
          <div class="col-md-2 text-right">${file.bitrate} bps</div>
          <div class="col-md-1 text-right"><time class="timeago" datetime="${file.last}"></time></div>`;
        $('#st' + i + 'file' + j).html(block);
      });

    });
    $('time.timeago').timeago();
  };

  this.newdata = (report) => {
    loading = 0;
    $('#oStreams').html(report.timestamp);
    if (report.status == 2) {
      setPanelState('#ringelSpiel', 'danger');
      $('#streamDash').html(`<div class="alert alert-warning" role="alert">${report.message}</div>`);
      count = 0;
      return;
    }
    setPanelState('#ringelSpiel', 'success');
    // if count of previous streams is equal to current, just update data
    if (report.streams.length === count) {
      this.update(report);
    } else {
      this.build(report);
    }
    count = report.streams.length;
  };

  this.build = (report) => {
    // clean the area
    $('#streamDash').html('<div class="panel-group" id="streamAccordion"></div>');
    $.each(report.streams, function(i, stream) {
      // reference for bargraph is 10Mbps
      var bar = stream.bitrate / 100000;
      if (bar > 100) {
        bar = 100;
      }
      var block = `<div class="panel panel-primary"><div id="stream${i}" class="panel-heading multicast"></div>
      <div id="chunkList${i}" class="panel-collapse collapse chunkGroup"><div class="container-fluid">
      <div class="row bg-info">
        <div class="col-md-6 text-center">Description</div>
        <div class="col-md-1 text-center">PID</div>
        <div class="col-md-2 text-center">Filesize</div>
        <div class="col-md-2 text-center">Bitrate</div>
        <div class="col-md-1 text-center">Last</div>
      </div>`;
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
  var updateStatus = 0;

  this.maintenance = () => {
    $('#maintenance').css('opacity', 0.4);
    $('#maintenance small').html("In progress...");
    $('#pod pre').text('');
    var formData = new FormData();
    var file = $('#upload')[0].files[0];
    formData.append('file', file);

    $.ajax({
      url: "/maintenance",
      dataType: 'json',
      data: formData,
      type: 'POST',
      processData: false,
      mimeTypes: 'multipart/form-data',
      contentType: false,
      cache: false,
      timeout: 10000
    }).always((item) => {
      if (item.success == 1) {
        $('#maintenance').removeClass('btn-primary btn-danger').addClass('btn-success').css('opacity', 1);
        $('#maintenance small').html(item.message);
      } else {
        $('#maintenance').removeClass('btn-primary btn-success').addClass('btn-danger').css('opacity', 1);
        if (item.message) {
          $('#maintenance small').html(item.message);
        } else {
          $('#maintenance small').html('Task failed');
        }
      }
      if ('pod' in item) {
        $('#pod').removeClass('hidden');
        $('#pod pre').text(item.pod);

        const $link = $('<a>');
        $(document.body).append($link);
        var url = URL.createObjectURL(new Blob([item.content], {
          type: 'text/plain'
        }));
        $link.attr('download', 'report');
        $link.attr('href', url)[0].click();
      }
    });
  };

  this.check = () => {
    $('#update').css('opacity', 0.4);
    $.ajax({
      url: '/git',
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      data: {
        update: this.updateStatus
      },
      timeout: 5000
    }).done((data) => {
      $('#update').css('opacity', 1);
      $('#update').removeClass('btn-warning btn-success btn-danger btn-info');
      $('#update small').html(data.message);
      if (data.success == 1) {
        this.updateStatus = 0;
        $('#update').addClass('btn-success');
      } else if (data.success == 2) {
        this.updateStatus = 1;
        $('#update').addClass('btn-info');
      } else {
        this.updateStatus = 0;
        $('#update').addClass('btn-danger');
      }
    }).fail(() => {
      this.updateStatus = 0;
      $('#update').css('opacity', 1);
      $('#update').removeClass('btn-warning btn-info btn-success').addClass('btn-danger');
      $('#update small').html('Connection error');
    });
  };

  this.refresh = () => {
    $('#systemStatus').html('loading...');
    $('#systemUptime').addClass('hidden');
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
        $('#systemStatus').html('Failed. Please reload!');
        $('#systemStatus').removeClass('label-default').addClass('label-danger');
        $('#systemVersion').html('');
        $('#systemEPG').html('');
        $('#systemPlayout').html('');
        $('#systemNTP').html('');
        $('#systemDatabase').html('');
        $('#systemWebgrab').html('');
        $('#systemAnnouncer').html('');
      },
      timeout: 100000
    });
  };

  this.update = (report) => {
    $('#systemStatus').removeClass('label-danger').addClass('label-default');
    $('#systemStatus').html(report.timestamp);
    $('#systemUptime time').timeago('update', report.systemStart);
    $('#systemUptime').removeClass('hidden').addClass('label-info');
    $('time.timeago').timeago();

    var block = "";
    $.each(Object.keys(report.version).sort(), function(i, key) {
      var no = report.version[key];
      if (no === null) {
        no = '-';
      }
      block += `<span class="label label-primary">${key}: ${no}</span>\n`;
    });
    $('#systemVersion').html(block);
    $('#systemEPG').html(this.generateBlock(report.modules.epg, true));
    $('#systemPlayout').html(this.generateBlock(report.modules.playout));
    $('#systemNTP').html(this.generateBlock(report.modules.ntp));
    $('#systemDatabase').html(this.generateBlock(report.modules.database));
    if (report.modules.webgrab) {
      $('#systemWebgrab').html(this.generateBlock(report.modules.webgrab, true));
      $('#systemWebgrab').parent().removeClass('hidden');
    } else {
      $('#systemWebgrab').parent().addClass('hidden');
    }
    if (report.modules.announcer) {
      $('#systemAnnouncer').html(this.generateBlock(report.modules.announcer, false));
      $('#systemAnnouncer').parent().removeClass('hidden');
    } else {
      $('#systemAnnouncer').parent().addClass('hidden');
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
        if (typeof x == 'number' || typeof x == 'string') {
          block += `${key}:${x}<br/>`;
        }
      });
    }
    block += `"><span class="label ${data.status === 0 ? 'label-success' : (data.status === 1 ? 'label-warning' : 'label-danger')}">${data.message}</span></a>`;
    return block;
  };

  $('time.timeago').timeago();
  $('[data-toggle="tooltip"]').tooltip({
    html: true,
    placement: 'right'
  });

  $('#systemInfo .panel-heading .btn').on('click', () => {
    this.refresh();
  });

  $('#update').on('click', () => {
    this.check();
  });

  $('#maintenance').on('click', () => {
    $('#upload').click();
  });

  $('#upload').on('change', () => {
    this.maintenance();
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
function CarouselPanel() {
  this.init = () => {
    $('#cPanel').removeClass('hidden');
    $('#sourceFileShow').val('');
    const $template = $('#browseReport tr.chunk').remove().first();
    $template.removeClass('hidden');
    this.browseTemplate = $template;
    $('#wMenuBrowse').trigger('click');
  };

  this.browse = () => {
    $('#configWizard').addClass('hidden');
    $('#uploadForm').addClass('hidden');
    $('#saveForm').addClass('hidden');
    $('#browseForm').removeClass('hidden');

    $('#browseReport table tr.chunk').remove();

    $.ajax({
      url: "/carousel/browse",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      timeout: 5000
    }).done((data) => {
      if (data.length) {
        data.forEach((item) => {
          const $row = this.browseTemplate.clone();
          $row.data('target', item.target);
          $row.find('td:nth-child(1)').html('<time class="timeago" datetime="' + item.timestamp + '">' + item.timestamp + '</time>&nbsp;<span class="hidden">' + item.timestamp + '</span>');
          $row.find('td:nth-child(2)').html(item.meta ? item.meta.title : '?');
          $row.find('td:nth-child(3)').html(item.meta ? item.meta.dst : '?');
          $row.find('td:nth-child(4)').html(item.pid);

          if (item.playing) {
            $row.addClass('playing');
            $row.find('td:nth-child(5) span').removeClass('hidden');
            if (item.ets) {
              $row.find('button[name=pause]').prop('disabled', false).removeClass('btn-default').addClass('btn-warning');
            }
          } else if (item.ets) {
            $row.addClass('paused');
            $row.find('button[name=play]').prop('disabled', false).removeClass('btn-default').addClass('btn-success');
          }

          if (item.ets) {
            // when we have source we can download
            $row.find('button[name=download]').prop('disabled', false).removeClass('btn-default').addClass('btn-primary');
          }
          $('#browseReport table').append($row);
        });
        $('time.timeago').timeago();
      } else {
        $('#browseReport table').append('<tr class="chunk"><td colspan="6" class="bg-info text-center"><b>Carousel empty!</b></td></tr>');
      }
    });
  };

  this.delete = () => {
    $.ajax({
      url: "/carousel/delete",
      dataType: 'json',
      type: 'POST',
      data: {
        target: this.target
      },
      timeout: 2000
    }).done((data) => {
      if (data.success && data.target === this.target) {
        var $row = $('tr').filter((index, item) => {
          return $(item).data('target') === this.target;
        });
        $row.animate({
          opacity: '0.0'
        }, 'slow', () => {
          $row.remove();
          // refresh list if empty
          if (!$('#browseReport table').find('tr.chunk').length) {
            this.browse();
          }
        });
      } else {}
    });
  };

  this.stop = () => {
    $.ajax({
      url: "/carousel/pause",
      dataType: 'json',
      type: 'POST',
      data: {
        target: this.target
      },
      timeout: 2000
    }).done((data) => {
      if (data.success && data.target === this.target) {
        var $row = $('tr').filter((index, item) => {
          return $(item).data('target') === this.target;
        });
        $row.find('td:nth-child(5) span').addClass('hidden');
        $row.removeClass('playing');
        $row.addClass('paused');
        $row.find('button[name=play]').prop('disabled', false).removeClass('btn-default').addClass('btn-success');
        $row.find('button[name=pause]').prop('disabled', true).removeClass('btn-warning').addClass('btn-default');
      } else {}
    });
  };

  this.preview = () => {
    $.ajax({
      url: '/dump/' + this.target,
      type: 'GET',
      timeout: 2000
    }).done((data) => {
      $('#preview').html(data);
      $('#modPreview').modal();
    });
  };

  this.play = () => {
    $.ajax({
      url: "/carousel/play",
      dataType: 'json',
      type: 'POST',
      data: {
        target: this.target
      },
      timeout: 2000
    }).done((data) => {
      if (data.success && data.target === this.target) {
        var $row = $('tr').filter((index, item) => {
          return $(item).data('target') === this.target;
        });
        $row.find('td:nth-child(5) span').removeClass('hidden');
        $row.addClass('playing');
        $row.removeClass('paused');
        $row.find('button[name=play]').prop('disabled', true).removeClass('btn-success').addClass('btn-default');
        $row.find('button[name=pause]').prop('disabled', false).removeClass('btn-default').addClass('btn-warning');
      } else {}
    });
  };

  $('#browseReport').on('click', 'td:nth-child(1),th:nth-child(1)', () => {
    $('#browseReport td:nth-child(1)>time').toggleClass('hidden');
    $('#browseReport td:nth-child(1)>span').toggleClass('hidden');
  });

  $('#browseReport').on('click', 'button', (event) => {
    var button = $(event.currentTarget).attr('name');
    this.target = $(event.currentTarget).closest('tr').data('target');

    if (button === 'delete') {
      $('#formConfirm').modal('show');
    } else if (button === 'preview') {
      this.preview();
    } else if (button === 'play') {
      this.play();
    } else if (button === 'pause') {
      this.stop();
    } else if (button === 'download') {
      window.location.href = '/carousel/' + this.target;
    }
  });

  $('#btnConfirm').on('click', () => {
    $('#formConfirm').modal('hide');
    this.delete();
  });

  $('#addFileForm button[name=upload]').on('click', (event) => {
    if (!$('#addFileForm').valid()) {
      return;
    }
    var formData = new FormData();
    var file = $('#sourceFile')[0].files[0];
    formData.append('file', file);
    $('#parseReport').empty();
    $('#parseReport').append('<p class="text-warning"><i class="glyphicon glyphicon-hourglass"></i> Waiting for validation!</p>');

    $('#step1').removeClass('active');
    $('#step2').addClass('active');
    $('#uploadForm').addClass('hidden');
    $('#saveForm').removeClass('hidden');
    $('#saveForm button[name=continue]').prop('disabled', true);
    $('.commands span').addClass('hidden');
    $('#saveForm div.alert-warning').addClass('hidden');
    $('#saveForm div.alert-success').addClass('hidden');

    $.ajax({
      url: "/carousel/upload",
      dataType: 'json',
      data: formData,
      type: 'POST',
      processData: false,
      mimeTypes: 'multipart/form-data',
      contentType: false,
      cache: false,
      timeout: 10000
    }).always((item) => {
      var validChunk = false;
      if ($.isArray(item.error)) {
        $('#parseReport').empty();
        $('#parseReport').append(`\n<p class="text-primary"><i class="glyphicon glyphicon-file"></i><span>Source file:</span>${item.source}</p>`);
        if (item.error.length) {
          item.error.forEach((message) => {
            $('#parseReport').append(`\n<p class="text-danger"><i class="glyphicon glyphicon-alert"></i><span>&nbsp;</span>${message}</p>`);
          });
        } else {
          validChunk = true;
        }
        if (validChunk) {
          $('#parseReport').append(`\n<p class="text-primary"><i class="glyphicon glyphicon-floppy-disk"></i><span>Title:</span>${item.title}</p>`);
          $('#parseReport').append(`\n<p class="text-primary"><i class="glyphicon glyphicon-envelope"></i><span>Destination:</span>${item.dst}</p>`);
          $('#parseReport').append(`\n<p class="text-primary"><i class="glyphicon glyphicon-shopping-cart"></i><span>Size:</span>${item.size}</p>`);
          $('#parseReport').append(`\n<p class="text-success"><i class="glyphicon glyphicon-ok"></i><span>&nbsp;</span>Enhanced chunk file valid.</p>`);
          // session check
          this.md5 = item.md5;
        } else {
          $('#parseReport').append('\n<p class="text-danger"><i class="glyphicon glyphicon-remove"></i><span>&nbsp;</span>File not valid. Fix errors and try again!</p>');
          this.md5 = null;
        }
      } else {
        $('#parseReport').empty();
        $('#parseReport').append('\n<p class="text-danger"><i class="glyphicon glyphicon-remove"></i><span>&nbsp;</span>Incorrect response from server.</p>');
      }
      if (validChunk) {
        $('#saveForm button[name=continue]').prop('disabled', false).addClass('btn-success').removeClass('btn-default');
      } else {
        $('#saveForm button[name=continue]').prop('disabled', true).removeClass('btn-success').addClass('btn-default');
      }
    });
    return;
  });

  $('#wMenuBrowse').on('click', (event) => {
    $('.wizard-menu button').removeClass('active');
    $(event.delegateTarget).addClass('active');
    this.browse();
  });

  $('#saveForm button[name=continue]').on('click', (event) => {
    var data = {
      md5: this.md5
    };
    $.ajax({
      url: "/carousel/save",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      data: data,
      timeout: 5000
    }).done((data) => {
      $('#saveForm button[name=continue]').prop('disabled', true).removeClass('btn-success').addClass('btn-default');
      if (data.success) {
        $('#saveForm div.alert-warning').addClass('hidden');
        $('#saveForm div.alert-success').removeClass('hidden');
      } else {
        $('#saveForm div.alert-warning').removeClass('hidden');
        $('#saveForm div.alert-success').addClass('hidden');
      }
    });
  });

  $('#wMenuUpload').on('click', (event) => {
    $('.wizard-menu button').removeClass('active');
    $(event.delegateTarget).addClass('active');
    $('#step1').addClass('active');
    $('#configWizard').removeClass('hidden');
    $('#step2').removeClass('active');
    $('#uploadForm').removeClass('hidden');
    $('#saveForm').addClass('hidden');
    $('#browseForm').addClass('hidden');
    $('#sourceFileShow').val('');
  });

  $('#saveForm button[name=upload]').on('click', (event) => {
    $('#wMenuUpload').click();
  });

  $('#step1').on('click', (event) => {
    $('#wMenuUpload').click();
  });

  $('#sourceFile').change((event) => {
    var fileName = $(event.currentTarget).val().match(/[^\\/]*$/)[0];
    $('#sourceFileShow').val(fileName);
  });

  $('#addFileForm').validate({
    debug: true,
    rules: {
      sourceFileShow: {
        required: true,
        extension: "gz"
      }
    },
    messages: {
      sourceFileShow: {
        required: "Input data file is required",
        extension: "Only gz files are accepted"
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

  $('html').on('dragover', (event) => {
    event.preventDefault();
    event.stopPropagation();
  });

  $('.upload-area').on('drop', (event) => {
    event.preventDefault();
    event.stopPropagation();

    var formData = new FormData();
    const files = Array.from(event.originalEvent.dataTransfer.files);
    files.forEach((file) => {
      formData.append('file', file);
    });

    $.ajax({
      url: "/carousel/upnsave",
      dataType: 'json',
      data: formData,
      type: 'POST',
      processData: false,
      mimeTypes: 'multipart/form-data',
      contentType: false,
      cache: false,
      timeout: 10000
    }).always((item) => {
      if ($.isArray(item) && item.length) {
        item.forEach((m) => {
          const id = Math.floor((1 + Math.random()) * 0x10000).toString(16).substring(1);
          $('#sidebar').append($(`<div id="${id}" class="alert alert-${m.success == 1 ? 'success' : 'warning'}">${m.message}</div>`));
          setTimeout(() => {
            $('#' + id).fadeOut('slow').remove();
          }, 8000);
        });
      } else {
        const id = Math.floor((1 + Math.random()) * 0x10000).toString(16).substring(1);
        $('#sidebar').append($(`<div id="${id}" class="alert alert-danger">Upload failed</div>`));
        setTimeout(() => {
          $('#' + id).fadeOut('slow').remove();
        }, 8000);
      }
      $('#wMenuBrowse').trigger('click');
    });

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
      $('#aPanel input[name=present]').val('');
      $('#following').prop('checked', false);
      $('#aPanel input[name=following]').val('');
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
    this.data = data;
    this.update();
  });
}
/// ------------------------------------------------------------------------------------------------------------------------------------------------------
function SchemePanel() {
  this.init = () => {
    $('#cPanel').removeClass('hidden');
    $('#sourceFileShow').val('');
    const $template = $('#browsePanel tr.scheme').remove().first();
    $template.removeClass('hidden');
    this.browseTemplate = $template;
    this.refresh();
    $('#wMenuBrowse').trigger('click');
  };

  this.refresh = () => {
    $('#browsePanel .report').empty();
    $('#browsePanel input').val('');
    $.ajax({
      url: "/scheme",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      timeout: 5000
    }).done((item) => {
      var $report = $('#browsePanel .report');
      $report.append(this.head(item));
      $('#browsePanel input').val(item.description);
      $('#browsePanel h4 span').html(item.timestamp);
    }).fail(() => {
      $('#browsePanel h3').html('ERROR');
    });
  };

  this.head = (item) => {
    return `<p class="text-primary"><i class="glyphicon glyphicon-file"></i><span>Source file:</span>${item.source}</p>
      <p class="text-primary"><i class="glyphicon glyphicon-film"></i><span>Services:</span>${item.channel}</p>
      <p class="text-primary"><i class="glyphicon glyphicon-transfer"></i><span>EIT:</span>${item.eit}</p>
      <p class="text-primary"><i class="glyphicon glyphicon-th-list"></i><span>Rules:</span>${item.rule}</p>`;
  };

  this.delete = () => {
    $.ajax({
      url: "/scheme/delete",
      dataType: 'json',
      type: 'POST',
      data: {
        target: this.target
      },
      timeout: 2000
    }).done((data) => {
      if (data.success && data.target === this.target) {
        var $row = $('tr').filter((index, item) => {
          return $(item).data('target') === this.target;
        });
        $row.find('td').animate({
          opacity: '0.0'
        }, 'slow', () => {
          $row.remove();
        });
      }
    });
  };

  this.prepare = () => {
    $.ajax({
      url: "/scheme/prepare",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      data: {
        target: this.target
      },
      timeout: 5000
    }).always((item) => {
      if (item.errorList) {
        this.mtime = item.mtime;
        $('#browsePanel').addClass('hidden');
        $('#uploadBody').addClass('hidden');
        $('#actionPanel').removeClass('hidden');
        $('#actionBody').removeClass('hidden');
        $('#validateBody').removeClass('hidden');
        $('#validateBody h4').html('Activate scheme:');
        $('#validateBody .clearfix').addClass('hidden');

        $('#configWizard').removeClass('hidden');

        $('#step1').removeClass('active');
        $('#step2').removeClass('active');
        $('#step3').addClass('active');

        $('#actionBody input').prop('disabled', false);
        $('#importScheme').prop('disabled', true);
        $('#stopEIT').prop('disabled', true);
        $('#deleteCarousel').parent().addClass('hidden');
        $('#stopCarousel').parent().removeClass('hidden');
        $('#resetDatabase').parent().removeClass('hidden');
        $('#importScheme').parent().removeClass('hidden');
        $('#stopEIT').parent().removeClass('hidden');

        $('#actionBody .clearfix').removeClass('hidden');
        $('#actionBody .alert').addClass('hidden');

        $('#actionBody button[name=loadScheme]').removeClass('hidden');
        $('#actionBody button[name=maintain]').addClass('hidden');

        $('#parseReport').empty();
        $('#parseReport').append(this.head(item));
        $('#validateBody input').val(item.description);
      } else {
        $('#formFailed').modal('show');
      }
    });
  };

  this.upload = (param) => {
    $.ajax({
      url: "/scheme/upload",
      dataType: 'json',
      data: param,
      type: 'POST',
      processData: false,
      mimeTypes: 'multipart/form-data',
      contentType: false,
      cache: false,
      timeout: 10000
    }).always((item) => {
      var validScheme = false;
      if (item.errorList) {
        $('#parseReport').empty();
        $('#parseReport').append(this.head(item));
        if (item.errorList.length) {
          item.errorList.forEach((item) => {
            $('#parseReport').append(`\n<p class="text-danger"><i class="glyphicon glyphicon-alert"></i><span>&nbsp;</span>${item}</p>`);
          });
        } else {
          validScheme = true;
        }
        if (validScheme) {
          $('#parseReport').append('\n<p class="text-success"><i class="glyphicon glyphicon-ok"></i><span>&nbsp;</span>Scheme valid.</p>');
          // session check
          this.mtime = item.mtime;
        } else {
          $('#parseReport').append('\n<p class="text-danger"><i class="glyphicon glyphicon-remove"></i><span>&nbsp;</span>Scheme not valid. Fix errors and try again!</p>');
          this.mtime = null;
        }
        $('#validateBody input').val(item.description);
      } else {
        $('#parseReport').append('\n<p class="text-danger">No response from server. Please retry!</p>');
      }
      $('#validateBody button[name=continue]').prop('disabled', !validScheme);
      $('#validateBody input[name=description]').prop('disabled', !validScheme);
    });
  };

  // wizard

  $('#wMenuWizard').on('click', (event) => {
    $('.wizard-menu button').removeClass('active');
    $(event.delegateTarget).addClass('active');
    $('#step1').addClass('active');
    $('#configWizard').removeClass('hidden');
    $('#step2').removeClass('active');
    $('#step3').removeClass('active');
    $('#actionPanel').removeClass('hidden');
    $('#uploadBody').removeClass('hidden');
    $('#actionBody').addClass('hidden');
    $('#validateBody').addClass('hidden');
    $('#browsePanel').addClass('hidden');
    $('#sourceFileShow').val('');
  });

  $('#addFileForm button[name=upload]').on('click', (event) => {
    if (!$('#addFileForm').valid()) {
      return;
    }
    var formData = new FormData();
    var file = $('#sourceFile')[0].files[0];
    formData.append('file', file);

    $('#parseReport').empty();
    $('#parseReport').append('\n<p class="text-warning"><i class="glyphicon glyphicon-hourglass"></i>Waiting for validation!</p>');

    $('#step1').removeClass('active');
    $('#step2').addClass('active');
    $('#uploadBody').addClass('hidden');
    $('#validateBody').removeClass('hidden');
    $('#validateBody h4').html('Result of <b>xls</b> to <b>yaml</b> conversion:');
    $('#validateBody input[name=description]').val('');
    $('#validateBody button[name=continue]').prop('disabled', true);
    $('#validateBody input[name=description]').prop('disabled', true);
    $('#reportSpan').addClass('hidden');
    $('#validateBody .clearfix').removeClass('hidden');

    this.upload(formData);
    return;
  });

  $('#validateBody button[name=continue]').on('click', (event) => {
    if (!$('#validateBody form').valid()) {
      return;
    }
    $('#validateBody .clearfix').addClass('hidden');
    var data = {
      description: $('#validateBody input[name=description]').val(),
      mtime: this.mtime
    };
    $.ajax({
      url: "/scheme/validate",
      dataType: 'json',
      type: 'POST',
      contentType: 'application/x-www-form-urlencoded',
      data: data,
      timeout: 5000
    }).always((data) => {
      if (data.success) {
        $('#actionBody').removeClass('hidden');
        $('#step2').removeClass('active');
        $('#step3').addClass('active');

        $('#actionBody input').prop('disabled', false);
        $('#importScheme').prop('disabled', true);
        $('#stopEIT').prop('disabled', true);
        $('#deleteCarousel').parent().addClass('hidden');
        $('#stopCarousel').parent().removeClass('hidden');
        $('#resetDatabase').parent().removeClass('hidden');
        $('#importScheme').parent().removeClass('hidden');
        $('#stopEIT').parent().removeClass('hidden');

        $('#actionBody .clearfix').removeClass('hidden');
        $('#actionBody .alert').addClass('hidden');

        $('#actionBody button[name=loadScheme]').removeClass('hidden');
        $('#actionBody button[name=maintain]').addClass('hidden');
      } else {
        $('#reportSpan').html('Failed to continue with activation ').removeClass('hidden');
      }
    });
  });

  // activate

  $('#actionBody button').on('click', (event) => {
    var action = event.delegateTarget.name;
    var data = {};
    $.each($('#actionBody input'), (i, check) => {
      data[check.id] = $(check).is(':checked') ? 1 : 0;
    });

    data.action = action;
    data.mtime = this.mtime;

    $('#actionBody .clearfix').addClass('hidden');
    $('#actionBody input').prop('disabled', true);
    $('#actionBody .alert').addClass('hidden');
    $('#actionBody .alert-default').empty();
    $('#actionBody div.alert-warning').removeClass('hidden');

    $.ajax({
      url: "/scheme/action",
      dataType: 'json',
      type: 'POST',
      data: data,
      timeout: 120000
    }).always((data) => {
      $('#actionBody div.alert-warning').addClass('hidden');
      if (data && $.isArray(data) && data.length) {
        var errorCount = 0;
        data.forEach((item) => {
          if (item.success) {
            $('#actionBody .alert-default').append(`\n<p class="text-success"><i class="glyphicon glyphicon-ok"></i> ${item.message}</p>`);
          } else {
            errorCount += 1;
            $('#actionBody .alert-default').append(`\n<p class="text-danger"><i class="glyphicon glyphicon-warning-sign"></i> ${item.message}</p>`);
          }
        });
        $('#actionBody div.alert-default').removeClass('hidden');
        if (errorCount) {
          $('#actionBody div.alert-success').addClass('hidden');
          $('#actionBody div.alert-danger').removeClass('hidden');
        } else {
          $('#actionBody div.alert-success').removeClass('hidden');
          $('#actionBody div.alert-danger').addClass('hidden');
        }
      } else {
        $('#actionBody div.alert-success').addClass('hidden');
        $('#actionBody div.alert-danger').removeClass('hidden');
      }
    });
  });

  // maintenance

  $('#wMenuAction').on('click', (event) => {
    $('.wizard-menu button').removeClass('active');
    $(event.delegateTarget).addClass('active');
    $('#configWizard').addClass('hidden');

    $('#browsePanel').addClass('hidden');
    $('#actionPanel').removeClass('hidden');

    $('#uploadBody').addClass('hidden');
    $('#validateBody').addClass('hidden');
    $('#actionBody').removeClass('hidden');

    $('#actionBody input').prop('disabled', false);
    $('#actionBody h3.panel-title').html('Maintenance');

    $('#actionBody form div').removeClass('hidden');

    $('#deleteCarousel').parent().removeClass('hidden');
    $('#resetDatabase').parent().addClass('hidden');
    $('#importScheme').parent().addClass('hidden');
    $('#stopEIT').parent().addClass('hidden');
    $('#actionBody button[name=loadScheme]').addClass('hidden');
    $('#actionBody button[name=maintain]').removeClass('hidden');

    $('#actionBody .clearfix').removeClass('hidden');

    $('#actionBody .alert').addClass('hidden');
  });

  // browse

  $('#wMenuBrowse').on('click', (event) => {
    $('.wizard-menu button').removeClass('active');
    $(event.delegateTarget).addClass('active');
    $('#configWizard').addClass('hidden');
    $('#browsePanel').removeClass('hidden');
    $('#actionPanel').addClass('hidden');

    $('#browseReport table tr.scheme').remove();

    $.ajax({
      url: "/scheme/browse",
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
          $row.find('a').attr('href', 'scheme/' + item.target);
          $row.data('target', item.target);
          $('#browseReport table').append($row);
        });
        $('time.timeago').timeago();
      } else {
        $('#browseReport table').append('<tr><td colspan="4" class="bg-info text-center"><b>Archive empty!</b></td></tr>');
      }
    });
  });

  // helper handler

  $('#browseReport').on('click', 'td:nth-child(1),th:nth-child(1)', () => {
    $('#browseReport td:nth-child(1)>time').toggleClass('hidden');
    $('#browseReport td:nth-child(1)>span').toggleClass('hidden');
  });

  $('#browseReport').on('click', 'button', (event) => {
    var button = $(event.currentTarget).attr('name');
    this.target = $(event.currentTarget).closest('tr').data('target');

    if (button === 'del') {
      $('#formConfirm').modal('show');
    } else if (button === 'act') {
      this.prepare();
    }
  });

  $('#btnConfirm').on('click', () => {
    $('#formConfirm').modal('hide');
    this.delete();
  });

  $('#validateBody button[name=upload]').on('click', (event) => {
    $('#wMenuWizard').click();
  });

  $('#step1').on('click', (event) => {
    $('#wMenuWizard').click();
  });

  $('#sourceFile').change((event) => {
    var fileName = $(event.currentTarget).val().match(/[^\\/]*$/)[0];
    $('#sourceFileShow').val(fileName);
  });

  $('#validateBody form').validate({
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

  $('#addFileForm').validate({
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

  $('html').on('dragover', (event) => {
    event.preventDefault();
    event.stopPropagation();
  });

  $('.upload-area').on('drop', (event) => {
    event.preventDefault();
    event.stopPropagation();

    var formData = new FormData();
    formData.append('file', event.originalEvent.dataTransfer.files[0]);

    $('.wizard-menu button').removeClass('active');
    $('#wMenuWizard').addClass('active');
    $('#actionPanel').removeClass('hidden');
    $('#uploadBody').removeClass('hidden');
    $('#actionBody').addClass('hidden');
    $('#browsePanel').addClass('hidden');
    $('#sourceFileShow').val('');
    $('#configWizard').removeClass('hidden');

    $('#step1').removeClass('active');
    $('#step2').addClass('active');
    $('#step3').removeClass('active');

    $('#parseReport').empty();
    $('#parseReport').append('<p class="text-warning"><i class="glyphicon glyphicon-hourglass"></i>Waiting for validation!</p>');

    $('#step1').removeClass('active');
    $('#step2').addClass('active');
    $('#uploadBody').addClass('hidden');
    $('#validateBody').removeClass('hidden');
    $('#validateBody h4').html('Result of <b>xls</b> to <b>yaml</b> conversion:');
    $('#validateBody input[name=description]').val('');
    $('#validateBody button[name=continue]').prop('disabled', true);
    $('#validateBody input[name=description]').prop('disabled', true);
    $('#reportSpan').addClass('hidden');
    $('#validateBody .clearfix').removeClass('hidden');

    this.upload(formData);
    return;
  });
}
