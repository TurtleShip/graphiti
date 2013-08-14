$(  function() {
    // get variables
    var time_series = parseInt( $("#highchart").attr('time_series') );

    // setting global options to display chart
    Highcharts.setOptions({
        chart: {
            backgroundColor: {
                linearGradient: [0, 0, 500, 500],
                stops: [
                    [0, 'rgb(255, 255, 255)'],
                    [1, 'rgb(240, 240, 255)']
                ]
            },
            borderWidth: 2,
            plotBackgroundColor: 'rgba(255, 255, 255, .9)',
            plotShadow: true,
            plotBorderWidth: 1,
         },

        xAxis: {
            title: {
                text: 'Data points taken every ' + time_series.toString() + ' seconds'

            },
            labels: {
                format: '{value}s'
            },
            //tickInterval: parseInt( $("#highchart").attr('time_series') ) * 1000
            tickInterval: time_series
        },

        plotOptions: {
            series: {
                pointStart: 0,
                pointInterval: time_series,
                connectNulls: true


            }
        }
    });

    // add event listener
    //var total_num = parseInt( $("highchart").attr('total_metric_num') );
    $("#metric_select").change( function() {
        drawChart( $(this).attr('value') );
    });

    // draw chart #0
    drawChart('0');

});


function drawChart(metric_id) {
    metric = $('#metric_' + metric_id);
    data_1 = JSON.parse( metric.attr('data_1') );
    data_2 = JSON.parse( metric.attr('data_2') );
    total_data_pt = metric.attr( 'total_data_pt' );
    std_dev = metric.attr( 'std_dev' );
    max_dev = metric.attr( 'max_dev' );
    unit = 'ms'; // TODO : dynamically pull this value instead of hard code

    $('#canvas').highcharts({
        charts: {
            type: 'bar'
        },
        title: {
            text: metric.attr('title')
        },

        subtitle: {
            text: '<p>'
                + 'Data points compared  : ' + total_data_pt + '<br/>'
                + 'Standard deviation : ' + std_dev + unit + '<br/>'
                + 'Maximum  deviation : ' + max_dev + unit
                + '</p>'
            ,
            align: 'left'
        },

        yAxis: {
            labels: {
                format: '{value}' + unit
            }
        },

        series: [{
            name: 'snapshot #1',
            connectNulls: true,
            data: data_1
        }, {
            name: 'snapshot #2',
            connectNulls: true,
            data: data_2
        }]
    });

}

