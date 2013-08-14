$(  function() {
    $("#group_select").change( function() {
        displayGroup( $(this).attr('value') );
    });

//    displayGroup("initial_snapshot");
    displayGroup($("#group_select").attr("value"));
});

function displayGroup(group_id) {
    group = $('#' + group_id);
    img_src_list = JSON.parse( group.attr('img_src_list') );

    canvas = $('#canvas');
    canvas.empty(); // clear out the canvas
    // start drawing snapshots on the canvas
    for(var i=0; i < img_src_list.length; i++) {
        canvas.append("<img src=" + img_src_list[i][1] + ">");
    }
}

