#!/usr/local/bin/perl

use Config;
use File::Basename qw(&basename &dirname);

# List explicitly here the variables you want Configure to
# generate.  Metaconfig only looks for shell variables, so you
# have to mention them as if they were shell variables, not
# %Config entries.  Thus you write
#  $startperl
# to ensure Configure will look for $Config{startperl}.

# This forces PL files to create target in same directory as PL file.
# This is so that make depend always knows where to find PL derivatives.
chdir(dirname($0));
($file = basename($0)) =~ s/\.PL$//;
$file =~ s/\.pl$//
	if ($Config{'osname'} eq 'VMS' or
	    $Config{'osname'} eq 'OS2');  # "case-forgiving"

open OUT,">$file.cgi" or die "Can't create $file: $!";

print "Extracting $file.cgi\n";

# In this section, perl variables will be expanded during extraction.
# You can use $Config{...} to use Configure variables.

print OUT <<'!NO!SUBS!';
#!/usr/local/bin/perl
# a perl CGI database table editor
#

$VERSION = "1.10";
sub Version { $VERSION; }

use strict;			# Check for inadvertent global variables
use vars qw($X $SchemaCache $CacheCount $PQ);
use CGI;			# Use CGI module for interaction
use RDBAL;
use RDBAL::Schema;


# Create CGI object
my($query);
$query = new CGI();

#
# Change editing table, if an 'Edit Table: $table' button was pushed
#
Change_Edit_Table($query);

#
# Get cgi parameters as $cgi_param entries to pass on
#
my($cgi_param) = PQEntry($query);

#
# Display Login screen, if necessary
#
if (!PQLogin($query,$cgi_param)) {
    exit;
}

#
# Setup error handlers
# The message handler is all that is currently necessary (or works).
#

my($error_string);
# different handler to check callbacks
if ($RDBAL::Layer{'SybaseDBlib'} || $RDBAL::Layer{'ApacheSybaseDBlib'}) {
    &Sybase::DBlib::dbmsghandle (\&msg_handler);
}

#
# Connect to database server
#
my($logged_in);
# Get connnection to database
if ( $X = RDBAL::Connect($cgi_param->{'username'},
			 $cgi_param->{'password'},
			 $cgi_param->{'server'},
			 $cgi_param->{'server_type'}) ) {
    if ( $X->UseDatabase($cgi_param->{'database'})) {
	$logged_in = 1;
    }
}
if (!$logged_in) {
    Login_Error($query,$cgi_param);
    exit;
}

#
# Get database schema object
#
my($cache_item) = $cgi_param->{'server'} . ':' . $cgi_param->{'database'}; 
if ($cgi_param->{'no_schemacache'}) {
    $SchemaCache->{$cache_item} =
	new RDBAL::Schema($X,
			  $cgi_param->{'database'},
			  -server => $cgi_param->{'server'},
			  -nocache => $cgi_param->{'no_schemacache'},
			  -server_type => $cgi_param->{'server_type'});
} else {
    if($SchemaCache->{$cache_item}) {
    } else {
	$SchemaCache->{$cache_item} =
	    new RDBAL::Schema($X,
			      $cgi_param->{'database'},
			      -server => $cgi_param->{'server'},
			      -nocache => $cgi_param->{'no_schemacache'},
			      -server_type => $cgi_param->{'server_type'});
    }
}

#
# Edit table
#
Edit($X,$query,$cgi_param,$SchemaCache->{$cache_item});

exit;
#=========================================================================
#
# End of script--beginning of subroutines
#


# Message Handler callback handler
# Called when there is a message from the server

sub msg_handler {
    my ($db, $message, $state, $severity, $text,
	$server, $procedure, $line)
	= @_;
    my($out_text);
    
    if ($severity > 0) {
	$out_text = $text;
	$out_text =~ s/^Line\s*\d+\:\s*//;
	($message == 102) or
	$error_string .= "$out_text ($message:$severity:$state)";
    }
    1;
}

#
# Change_Edit_Table($query);
#
sub Change_Edit_Table {
    my($query) = shift;
    my($table);

    if (defined($query->param('edit_lookup'))) {
	map {
	    if (/^pqold_/) {
		$query->delete($_);
	    }
	} $query->param;
	($table) = $query->param('edit_lookup') =~ /^Edit Table:\s+(.*)$/;
	$table =~ s/^\s*//g;
	$table =~ s/\s*$//g;
	$query->param('table',$table);
    }
}

#
# $td_label = TD_Field_Label($field,$required,$rlabel,$helppage);
#

sub TD_Field_Label {
    my($field) = shift;
    my($required) = shift;
    my($rlabel) = shift;
    my($helppage) = shift;
    my($label);
    my($td_label);

    $field =~ s/_______________/ and_/g;
    $label = (defined($rlabel->{$field})) ?
	$rlabel->{$field} : uc_string($field);
    $td_label = '<TD WIDTH="25%" VALIGN="TOP"><p align="right">';
    if ($helppage !~ /^\s*$/) {
	$td_label .= '<A HREF="'. $helppage .'#'. $field .'">' .
	    $label . $required . "</A></TD>";
    } else {
	$td_label .= $label . $required . "</TD>";
    }
    return $td_label;
}


#
# Output CGI forms editing screen
#
# Edit($X,$query,$cgi_param,$schema);
#

sub Edit {
    my($X) = shift;
    my($query) = shift;
    my($cgi_param) = shift;
    my($schema) = shift;
    my($rlabel);
    my($self_url) = $query->self_url;
    my($body_bgcolor) = (defined($cgi_param->{'web_body_bgcolor'})) ?
	$cgi_param->{'web_body_bgcolor'} : 'silver';
    my($table) = $cgi_param->{'table'};
    my(%qbe_fields);
    my($javascript);
    my(%lookup_hash);
    my($helppage) = $cgi_param->{'helppage'};
    my(%selects);
    my($default);
    my($required);
    my($server) = $cgi_param->{'server'};
    my($database) = $cgi_param->{'database'};
    my($fullname) = $server . '.' . $database . '.' . $table;
    my($td_label);
    my(%values);
    my(%lookup_fields);
    my(%multi_lookup_fields);
    my($multi_field);
    my($field);
    my($html_page);
    my($ltable,$lkey,$ldescription);
    my(%lookup_tables);
    my($col_count);
    my($html_changes);
    my(@radio_edit);
    my(%done_tuple);
    my($rl_field);
    my($rl_value);

    if (!$cgi_param->{'pqdebug'}) {
	$self_url =~ s/\?.*$//;
    }
    undef %lookup_hash;

    $html_changes .= execute_changes($X,$schema,$table,$query);

    map {
	($rl_field, $rl_value) = split(';');
	$rlabel->{$rl_field} = $rl_value;
    } split(',',$cgi_param->{'labels'});

    if (defined($query->param('radio_edit')) &&
	!defined($query->param('edit_lookup')) &&
	$query->param('radio_edit') ne $table) {
	map {
	    if (/^pqold_/) {
		$query->delete($_);
	    }
	} $query->param;
	$table = $query->param('radio_edit');
	$table =~ s/^\s*//g;
	$table =~ s/\s*$//g;
	$query->param('table',$table);
	$fullname = $server . '.' . $database . '.' . $table;
    }


    %qbe_fields = qbe_fields($schema,$table);

    # Output HTML
#    if ($query->request_method() eq 'GET' || $query->user_agent() !~ /MSIE/ ||
#	$query->server_software =~ /IIS/) {
	print $query->header(-type => 'text/html',
			     -status => '200 OK');
#    }
    $html_page .= "\n";
#    $html_page .= '<H1 ALIGN="CENTER">Editing: ' . $fullname . "</H1>\n";
    %lookup_fields = find_lookups($schema,$table);
    map {
	if (/\,/) {
	    $multi_field = $_;
	    map {
		$multi_lookup_fields{$_} = $multi_field;
	    } split(',');
	}
    } (keys %lookup_fields);

    $html_page .= $html_changes;

    %values = get_values($X,$schema,$table,\%qbe_fields,$query);

    if (defined($error_string)) {
	$html_page .= "Database Error: $error_string<P>\n";
    }

    $html_page .= $query->start_form(-method => 'POST',
				     -name =>  "PQEdit",
				     -onSubmit => "return check_keys()",
				     -action => $self_url);
    if (defined($query->param('begin_html_include'))) {
	$html_page .= html_file_include($query->param('begin_html_include'));
    }
    if (defined($query->param('subedit_tables'))) {
	if (defined($query->param('button_subedit'))) {
	    $html_page .= "<TABLE BORDER=\"0\" WIDTH=\"100%\" CELLSPACING=\"0\">\n<TR>\n";
	    $col_count = 1;
	    map {
		if (!$lookup_tables{$_} && $_ ne $table) {
		    $html_page .=  "<TD>" .
			$query->submit(-name => 'edit_lookup',
				       -value => "Edit Table: $_") .
					   "</TD>\n";
		    if (++$col_count > 2) {
			$col_count = 1;
			$html_page .= "</TR>\n</TR>\n";
		    }
		}
	    } split(',',$query->param('subedit_tables'));
	    $html_page .= "</TR>\n</TABLE>\n<HR>";
	} else {
	    push @radio_edit, ($table);
	    map {
		if ($_ ne $table) {
		    push @radio_edit, ($_);
		}
	    } split(',',$query->param('subedit_tables'));
	    if (@radio_edit > 1) {
		$html_page .= "<BIG><B>Next edit table:</B></BIG>\n";
		$html_page .= $query->radio_group(-name => 'radio_edit',
						  -values => \@radio_edit,
						  -default => $table,
						  -columns => 6);
		$html_page .= "\n";
	    }
	}
    }
    $html_page .= '<HR><TABLE BORDER="0" WIDTH="100%" CELLSPACING="0">'."\n";

    $html_page .= <<"EndHTML";
    <tr>
      <td colspan="3" align="center"><input TYPE="submit" VALUE="First Entry" NAME="First"
      tabindex="7" style="background-color: gray"> <input TYPE="submit" VALUE="Retrieve Using Search fields"
      NAME="retrieve" tabindex="8" style="background-color: gray"> <input TYPE="submit"
      VALUE="Next Entry &gt;" NAME="Next" tabindex="9" style="background-color: gray">
      </td>
    </tr>
EndHTML
    $html_page .= '<TR><TD COLSPAN="3"><HR></TD></TR>'."\n";
    $html_page .= <<"EndHTML";
    <tr>
      <th colspan=\"2\">
	  <P ALIGN="LEFT"><BIG>Searchable and Editable Fields:</BIG></P>
      </th>
      <th><p align="right"><em>* Required fields.</em></p></th>
    </tr>
EndHTML

    undef %done_tuple;
    map {
	$field = $_;
	if (defined($qbe_fields{$field}) &&
	    !defined($done_tuple{$field})) {
	    $required = ($schema->Field_Null($table,$field)) ? '' : '*';
	    if (defined($multi_lookup_fields{$field})) {
		($ltable,$lkey,$ldescription) =
		    split("\t",$lookup_fields{$multi_lookup_fields{$field}});
		%lookup_hash =
		    get_multi_lookup($X,$cgi_param,$ltable,$lkey,$ldescription);
		if (defined(%lookup_hash)) {
		    $multi_field =
			join('_______________',split(',',$multi_lookup_fields{$field}));
		    map {
			$done_tuple{$_} = 1;
		    } split(',',$multi_lookup_fields{$field});
		    $values{$multi_field} =
			join("\t",
			     @values{split(',',$multi_lookup_fields{$field})});
		    $field = $multi_field;
		}
	    } else {
		($ltable,$lkey,$ldescription) = split("\t",$lookup_fields{$field});
		%lookup_hash = get_lookup($X,$cgi_param,$ltable,$lkey,$ldescription);
	    }
	    $td_label = TD_Field_Label($field,$required,$rlabel,$helppage);
	    $lookup_tables{$ltable} = 1;
	    if (defined(%lookup_hash) && $required eq '') {
		$lookup_hash{''} = '<Select A Value>';
	    }
	    $html_page .= Edit_Row($field,$td_label,$values{$field},$table,
				   $schema,\%lookup_hash,$cgi_param,$ltable,1);
	    if (defined(%lookup_hash)) {
		$selects{$field} = 1;
	    }
	    undef %lookup_hash;
	}
    } $schema->Table_Fields($table), $schema->View_Fields($table);

    $html_page .= '<TR><TD COLSPAN="3"><HR></TD></TR>'."\n";
    $html_page .= <<"EndHTML";
    <tr>
      <th colspan=\"3\" align=\"center\">
           <P ALIGN=\"LEFT\"><BIG>Nonsearchable but Editable Fields:</BIG></P>
      </th>
    </tr>
EndHTML
    map {
	$field = $_;
	if (!defined($qbe_fields{$field}) &&
	    !defined($done_tuple{$field})) {
	    $required = ($schema->Field_Null($table,$field)) ? '' : '*';
	    if (defined($multi_lookup_fields{$field})) {
		($ltable,$lkey,$ldescription) =
		    split("\t",$lookup_fields{$multi_lookup_fields{$field}});
		%lookup_hash =
		    get_multi_lookup($X,$cgi_param,$ltable,$lkey,$ldescription);
		if (defined(%lookup_hash)) {
		    $multi_field =
			join('_______________',split(',',$multi_lookup_fields{$field}));

		    map {
			$done_tuple{$_} = 1;
		    } split(',',$multi_lookup_fields{$field});
		    $values{$multi_field} =
			join("\t",
			     @values{split(',',$multi_lookup_fields{$field})});
		    $field = $multi_field;
		}
	    } else {
		($ltable,$lkey,$ldescription) = split("\t",$lookup_fields{$field});
		%lookup_hash = get_lookup($X,$cgi_param,$ltable,$lkey,$ldescription);
	    }
	    $td_label = TD_Field_Label($field,$required,$rlabel,$helppage);
	    $lookup_tables{$ltable} = 1;
	    if (defined(%lookup_hash) && $required eq '') {
		$lookup_hash{''} = '<Select A Value>';
	    }
	    $html_page .= Edit_Row($field,$td_label,$values{$field},$table,
				   $schema,\%lookup_hash,$cgi_param,$ltable);
	    if (defined(%lookup_hash)) {
		$selects{$field} = 1;
	    }
	    undef %lookup_hash;
	}
    } $schema->Table_Fields($table), $schema->View_Fields($table);

    $html_page .= "</TABLE>\n";

    $html_page .= '<HR><TABLE BORDER="0" WIDTH="100%" CELLSPACING="0">'."\n";
    $html_page .= <<"EndHTML";
    <tr>
      <td align="center"><input TYPE="submit" VALUE="Add New (Insert)" NAME="Insert" tabindex="10" style="background-color: gray">
      <input TYPE="submit" VALUE="Update" NAME="Update" tabindex="11" style="background-color: gray">
      <input TYPE="submit" VALUE="Delete" NAME="Delete" tabindex="12" style="background-color: gray"></td>
    </tr>
    <tr>
      <td align="center"><p><input TYPE="reset"
      VALUE="Reset Form Values" NAME="Reset Form" tabindex="13" style="background-color: gray">
      </td>
    </tr>
      <td align="center"><input TYPE="submit" VALUE="Clear Form" NAME="clear" tabindex="14" style="background-color: gray"></p>
      </td>
    </tr>
EndHTML


    $html_page .= "</TABLE><HR>\n";
    if (defined($query->param('middle_html_include'))) {
	$html_page .= html_file_include($query->param('middle_html_include'));
    }
    $javascript = pqedit_javascript($schema,$table,{},\%qbe_fields,\%selects,\%multi_lookup_fields);

    print "\n";
    print $query->start_html(-title => "PQ Edit: $fullname",
			     -author => 'brian@ibc.wustl.edu',
			     -script => $javascript,
			     -BGCOLOR => $body_bgcolor);
    print $html_page;
    print PQHidden_Parameters($query,$cgi_param);
    # Pass old values of primary key fields or of all fields
    # so that we can do updates
    map {
	$query->delete("pqold_$_");
	print $query->hidden("pqold_$_",$values{$_}) . "\n";
    } (($schema->Primary_Keys($table) > 0) ?
	$schema->Primary_Keys($table) : (keys %values));
    if (defined($query->param('end_html_include'))) {
	print html_file_include($query->param('end_html_include'));
    }
    print "\n" . $query->end_form;
    print "\n" . $query->end_html;
}

#
# execute_changes($X,$schema,$table,$query);
#

sub execute_changes {
    my($X) = shift;
    my($schema) = shift;
    my($table) = shift;
    my($query) = shift;
    my($field);
    my(@fields);
    my(@values);
    my(@update);
    my(@delete_where);
    my(@update_where);
    my($value);
    my($command);
    my($show);
    my($html_page);

    if (!defined($query->param('Insert')) &&
	!defined($query->param('Update')) &&
	!defined($query->param('Delete'))) {
	return;
    } 
    map {
	if (/pq_/) {
	    $field = $_;
	    $field =~ s/^pq_//;
	    $value = $query->param($_);
	    $value =~ s/\t/ /g;
	    if (!defined($value) ||
		$value eq '') {
		$value = 'NULL';
	    } else {
		$value = $schema->Quote_Field($table,$field,$value);
	    }
	    if (! $schema->Field_Identity($table,$field)) {
		push @fields, ($field);
		push @values, ($value);
		push @update, ("$field=$value");
	    }
	    if (defined($query->param("pqold_$field"))) {
		push @delete_where, ("$field=$value");
	    }
	}
    } $query->param;
    map {
	if (/pqold_/) {
	    $field = $_;
	    $field =~ s/^pqold_//;
	    $value = $query->param($_);
	    if (!defined($value) ||
		$value eq '') {
		$value = 'NULL';
	    } else {
		$value = $schema->Quote_Field($table,$field,$value);
	    }
	    push @update_where, ("$field=$value");
	}
    } $query->param;
    if (defined($query->param('Insert'))) {
	$show = 'insert';
	$command = "insert into $table \n" .
	    ' ( ' . join(', ',@fields) . " ) \n" .
		' values( ' . join(', ',@values) . ' ) ';
    } elsif (defined($query->param('Update'))) {
	$show = 'update';
	$command = "update $table set " . join(', ',@update) .
	    ' where ' . join(' and ',@update_where);
    } elsif (defined($query->param('Delete'))) {
	$show = 'delete';
	$command = "delete from $table " .
	    ' where ' . join(' and ',@delete_where);
    }
    if ($query->param('pqdebug')) {
	$html_page .= "<P>$command<P>\n";
    }
    ( $X->Sql($command) )
	or ($html_page .= "<P>Unable to $show entry<P>\n");
    if ($X->RowCount() > 0) {
	$html_page .= "<P>Successful $show of " . $X->RowCount() . " entry.<P>\n";
    } else {
	$html_page .= "<P><BIG><BIG><B>Unsuccessful $show:</B></BIG></BIG><P> $error_string<P>\n";
	undef $error_string;
    }
    while ($X->More_Results()) {}
    return $html_page;
}


#
#    $where = Next_Where($connection,$schema,$table,$cgi_query);
#

sub Next_Where {
    my($X) = shift;
    my($schema) = shift;
    my($table) = shift;
    my($query) = shift;
    my(@row);
    my($command);
    my($i);
    my(%value);
    my($where);
    my($value);
    my($qvalue);
    my($percent) = '%';
    my($underscore) = '_';
    my(@primary_keys) = $schema->Primary_Keys($table);
    my($last);
    my($rowcount);

    map {
	$value = $query->param("pq_$_");
	if (defined($value) &&
	    $value !~ /^\s*$/ &&
	    $value ne '_NULL_') {
	    $value =~ s/\*/$percent/g;
	    $value =~ s/\?/$underscore/g;
	    $qvalue = $schema->Quote_Field($table,$_,$value);
	    $value{$_} = $qvalue;
	}
    } @primary_keys;
    $last = $#primary_keys;

    do {
	$where = 'where ';
	for ($i = 0; $i <= $last;$i++) {
	    $_ = $primary_keys[$i];
	    if (defined($value{$_})) {
		if ($i == $last) {
		    $where .= ' and '.$_. ' > ' .$value{$_};
		} else {
		    $where .= ' and '.$_. ' = ' .$value{$_};
		}
	    }
	}
	$last--;
	$where =~ s/^where\s+and\s+/where /;
	if ($where =~ /^\s*where\s*$/ ) {
	    undef $where;
	}

	$command = "select count(*) from $table $where";

	$X->Sql($command);
	@row = $X->NextRow();
	while ($X->More_Results()) {}
    } while(!defined($row[0]) || $row[0] == 0);
    return $where;
}


#
#    %values = get_values($connection,$schema,$table,$cgi_query);
#

sub get_values {
    my($X) = shift;
    my($schema) = shift;
    my($table) = shift;
    my($qbef) = shift;
    my($query) = shift;
    my(@field) = $schema->Fields($table);
    my(@row);
    my($command);
    my($i);
    my(%value);
    my($where);
    my($value);
    my($qvalue);
    my($rowcount) = 1;
    my($direction) = ' = ';
    my($col_value);
    my($percent) = '%';
    my($underscore) = '_';

    if (defined($query->param('clear')) ||
	defined($query->param('Delete')) ) {
	map {
	    if (/pq_/) {
		$query->delete($_);
	    }
	} $query->param;
	return %value;
    }
    if (!defined($query->param('First')) &&
	!defined($query->param('Next'))) {
	$where = 'where ';
	map {
	    $value = $query->param("pq_$_");
	    if (defined($query->param("pqsearch_$_")) &&
		defined($value) &&
		$value !~ /^\s*$/ &&
		$value ne '_NULL_') {
		$value =~ s/\*/$percent/g;
		$value =~ s/\?/$underscore/g;
		$qvalue = $schema->Quote_Field($table,$_,$value);
		if ($direction eq ' = ' && $qvalue ne $value) {
		    $where .= ' and '.$_. ' LIKE ' .$qvalue;
		} else {
		    $where .= ' and '.$_. $direction .$qvalue;
		}
	    }
	} (keys %{$qbef});
	$where =~ s/^where\s+and\s+/where /;
	if ($where =~ /^\s*where\s*$/ ) {
	    undef $where;
	}
    }

    if (defined($query->param('Next'))) {
	$rowcount = 1;
	$where = Next_Where($X,$schema,$table,$query);
    }

    if ($query->param('server_type') eq 'oracle') {
	if (!defined($where)) {
	    $where = " where ROWNUM <= $rowcount ";
	} else {
	    $where .= " and ROWNUM <= $rowcount ";
	}
	$command = <<"EndQuery";
	    select * from $table $where
EndQuery
    } else {
	$command = <<"EndQuery";
	set rowcount $rowcount
	    select * from $table $where
		set rowcount 0
EndQuery
    }
    if ($query->param('pqdebug')) {
	$error_string .= "DEBUG> $command<P>\n";
    }
    $X->Sql($command);
    do {
	while(@row = $X->NextRow()) {
	    undef %value;
	    if ($X->Regular_Row()) {
		foreach $col_value (@row) {
		    $col_value =~ s/\t/ /g;
		}
		for ($i = 0; $i < @field; $i++) {
		    $row[$i] =~ s/^\s*//g;
		    $row[$i] =~ s/\s*$//g;
		    $value{$field[$i]} = $row[$i];
		}
	    }
	}
    } while ($X->More_Results());
    if (defined($query->param('retrieve')) ) {
	map {
	    if (/pq_/) {
		$query->delete($_);
	    }
	} $query->param;
	return %value;
    }
    return %value;
}

    
#
#    Edit_Row($_,$td_label,$default,$table,$schema,\%lookup_hash,$cgi_param,$ltable);
#

sub Edit_Row {
    my($field) = shift;
    my($td_label) = shift;
    my($default) = shift;
    my($table) = shift;
    my($schema) = shift;
    my($lookup_hash) = shift;
    my($cgi_param) = shift;
    my($lookup_table) = shift;
    my($search) = shift;
    my($output);
    my($display_length);
    my(@keys);
    my($lookup_button);
    my($textarea_rows);
    my($search_click);

    if (defined($query->param("pq_$field")) &&
	!defined($query->param("retrieve"))) {
	$query->param("pq_$field",$default);
    }
    if ($schema->Field_Type($table,$field) =~ /bit/) {
	$lookup_hash = { 0 => 'False', 1 => 'True' };
    }
    if ($search) {
	$search_click = $query->checkbox(-name => "pqsearch_$field",
					 -checked => 'checked',
					 -value => 'ON',
					 -label => '');
    }
    if (defined(%{$lookup_hash})) {
	@keys = (sort (keys %{$lookup_hash}));
	$output .= "<TR>$td_label";
	if (defined($lookup_table) && $lookup_table ne '') {
	    $lookup_button =  "</TD><TD ALIGN=\"RIGHT\">" .
		    $query->submit(-name => 'edit_lookup',
				   -value => "Edit Table: $lookup_table");
	}
	$output .= "<TD>".
	    $search_click .
		$query->popup_menu(-name => "pq_$field",
				   -values => \@keys,
				   -default => $default,
				   -labels => $lookup_hash) .
				       "$lookup_button</TD></TR>\n";
	undef $lookup_button;
    } else {
	$display_length = $schema->Field_Width($table,$field);
	$output .= "<TR>$td_label";
	if ($display_length > $cgi_param->{'web_textarea_columns'}) {
	    $textarea_rows = (int $display_length /
			      $cgi_param->{'web_textarea_columns'} 
			      < $cgi_param->{'web_textarea_rows'}) ?
		int $display_length / $cgi_param->{'web_textarea_columns'}
	    : $cgi_param->{'web_textarea_rows'};
	    $output .= "<TD>".
		$search_click .
		    $query->textarea(-name => "pq_$field",
				     -default => $default,
				     -rows => $textarea_rows,
				     -columns => $cgi_param->{'web_textarea_columns'},
				     -size => $display_length,
				     -maxlength => $display_length,
				     -LANGUAGE => "JavaScript",
				     -OnFocus => 'PQEdit.pq_'.$field.'.select()') .
					 "</TD></TR>\n";
	} else {
	    $output .= "<TD>".
		$search_click .
		    $query->textfield(-name => "pq_$field",
				      -default => $default,
				      -size => $display_length+1,
				      -maxlength => $display_length,
				      -LANGUAGE => "JavaScript",
				      -OnFocus => 'PQEdit.pq_'.$field.'.select()') .
					  "</TD></TR>\n";
	}
    }
    return $output;
}

#
# qbe_fields($schema,$table)
#

sub qbe_fields {
    my($schema) = shift;
    my($table) = shift;
    my($lqbef);
    my($n);
    my(%qbef);
    my(%nqbef);

    map {
	$lqbef = ' ';
	$n = 0;
	map {
	    s/^\s//g;
	    s/\s$//g;
	    if (!defined($qbef{$_}) || $nqbef{$_} > $n) {
		$qbef{$_} = "$lqbef\t$n";
		$nqbef{$_} = $n;
	    }
	    $lqbef = $_;
	    $n++;
	} split(',');
    } $schema->Keys($table,'User Table');
    return %qbef;
}

#
# $javascript = pqedit_javascript($schema,$table,\%label,\%qbe_fields,\%selects,\%multi_lookup_fields);
#

sub pqedit_javascript {
    my($schema) = shift;
    my($table) = shift;
    my($rlabel) = shift;
    my($qbef) = shift;
    my($selects) = shift;
    my($multi_lookup_fields) = shift;
    my(%done_multi);
    my($multi_field);
    my($javascript) = <<"EndQuery";
    function check_keys() {
	var r;
	r = "";
	formObj = document.PQEdit;
EndQuery
    my($label,$depends,$indent);
	my($depend_label,$check_name,$depends_name);
	my(@form_fields);
	
	map {
	    if (defined($qbef->{$_}) &&
		!defined($multi_lookup_fields->{$_})) {
		push @form_fields, ($_);
	    }
	} $schema->Table_Fields($table), $schema->View_Fields($table);
	map {
	    $label = (defined($rlabel->{$_})) ? $rlabel->{$_} : uc_string($_);
	    ($depends, $indent) = split("\t",$qbef->{$_});
	    if ($depends ne ' ') {
		if (defined($multi_lookup_fields->{$depends})) {
		    $multi_field = $multi_lookup_fields->{$depends};
		    $multi_field =~ s/\,/\_______________/g;
		    $depends = $multi_field;
		}
		$depend_label = (defined($rlabel->{$depends})) ?
		    $rlabel->{$depends} : uc_string($depends);
		$check_name = ($selects->{$_}) ?
		    "formObj.pq_$_.".'options['."formObj.pq_$_.selectedIndex".'].value'
			: "formObj.pq_$_.value";
		$depends_name = ($selects->{$depends}) ?
		    "formObj.pq_$depends.".'options['."formObj.pq_$depends.selectedIndex".'].value'
			: "formObj.pq_$depends.value";
		$javascript .= <<"EndQuery";
		if ( ($check_name != "" &&
		      $check_name != "_NULL_" ) &&
		    ($depends_name == "" ||
		     $depends_name == "_NULL_" ) ) {
		    r += "In order to specify $label, a value needs to be selected for $depend_label.  ";
		}
EndQuery
		$check_name = "formObj.pqsearch_$_.checked";
		$depends_name = "formObj.pqsearch_$depends.checked";
		$javascript .= <<"EndQuery";
		if ( $check_name &&
		    !$depends_name) {
		    r += "In order to specify $label, a value needs to be selected for $depend_label.  ";
		}
EndQuery
}
	} @form_fields;
	$javascript .= <<"EndQuery";
	if (r == "") {
	    return true;
	} else {
	    alert(r);
	    return false;
	}
    }
EndQuery
    return $javascript;
}

#
# uc_string($instring);
#
sub uc_string {
    my($instring) = shift;
    my(@label);
    map {
	push @label, (ucfirst $_);
    } split('_',$instring);
    return join(' ',@label);
}

#
#    %lookup_fields = find_lookups($schema,$table);
#

sub find_lookups {
    my($schema) = shift;
    my($table) = shift;
    my($parent);
    my(@relation);
    my(%lookups);
    my($field);
    my($pfield);
    my($first_pfield);
    my($description);
    my(@fields);
    my(@pfields);
    my($single_key) = 1;
    my($multi_key);
    my($number_tuples);
    my($array_ref);
    my($i);

    map {
	$parent = $_;
	@relation = $schema->Relation($_,$table);
	($first_pfield) = split("=",$relation[0]);
	undef @pfields;
	map {
	    ($pfield, $field) = split("=");
	    if ($pfield ne $first_pfield) {
		$single_key = 0;
	    }
	    if (!defined($multi_key->{$pfield})) {
		$multi_key->{$pfield} = [];
		push @pfields, ($pfield);
	    }
	    push @{$multi_key->{$pfield}}, ($field);
	} @relation;
	if (@relation <= 1) {
	    ($pfield, $field) = split("=",$relation[0]);
	    $description = '';
	    map {
		if (/description/) {
		    $description = $_;
		}
	    } $schema->Table_Fields($parent);
	    if ($description eq '') {
		$description = $pfield;
	    }
	    $lookups{$field} = "$parent\t$pfield\t$description";
	} elsif ($single_key) {
	    map {
		($pfield, $field) = split("=");
		$description = '';
		map {
		    if (/description/) {
			$description = $_;
		    }
		} $schema->Table_Fields($parent);
		if ($description eq '') {
		    $description = $pfield;
		}
		$lookups{$field} = "$parent\t$pfield\t$description";
	    } @relation;
	} else {
	    $description = '';
	    map {
		if (/description/) {
		    $description = $_;
		}
	    } $schema->Table_Fields($parent);
	    if ($description eq '') {
		$description = join(',',@pfields);
	    }
	    $number_tuples = $#{$multi_key->{$pfields[0]}};
	    for ($i = 0; $i <= $number_tuples; $i++) {
		undef @fields;
		map {
		    $array_ref = $multi_key->{$_};
		    push @fields, ($array_ref->[$i]);
		} @pfields;
		$lookups{join(',',@fields)} = "$parent\t".
		    join(',',@pfields)."\t$description";
	    }
	    map {
		($pfield, $field) = split("=");
		push @fields, ($field);
		push @pfields, ($pfield);
	    } @relation;
	}
    } $schema->Parents($table);
    return %lookups;
}

#
# %lookup_hash = get_lookup($X,$cgi_param,$ltable,$lkey,$ldescription);
#

sub get_lookup {
    my($X) = shift;
    my($cgi_param) = shift;
    my($object) = shift;
    my($key_field) = shift;
    my($description_field) = shift;
    my($query) = "select distinct $key_field, $description_field from $object";
    my(%lookup_hash);
    my(@row);
    my($value);

    map {
	s/^\s*//g;
	s/\s*$//g;
	if ($object eq $_) {
	    return undef;
	}
    } split(',',$cgi_param->{'disable_lookup'});
    if (defined($key_field) &&
	$key_field !~ /^\s*$/ &&
	defined($description_field) &&
	$description_field !~ /^\s*$/ &&
	defined($object) &&
	$object !~ /^\s*$/) {
	$X->Sql($query);
	while(@row = $X->NextRow()) {
	    if ($X->Regular_Row()) {
		$row[0] =~ s/^\s*//g;
		$row[0] =~ s/\s*$//g;
		$row[1] =~ s/^\s*//g;
		$row[1] =~ s/\s*$//g;
		if ($row[0] !~ /^\s*$/ ) {
		    if (defined($row[1])) {
			$lookup_hash{$row[0]} = $row[1];
		    } else {
			$lookup_hash{$row[0]} = $row[0];
		    }
		}
	    }
	}
	while ($X->More_Results()) {}
    }
    return %lookup_hash;
}

#
# %lookup_hash = get_multi_lookup($X,$cgi_param,$ltable,$lkey,$ldescription);
#

sub get_multi_lookup {
    my($X) = shift;
    my($cgi_param) = shift;
    my($object) = shift;
    my($key_field) = shift;
    my(@key_fields) = split(',',$key_field);
    my($num_key_field) = $#key_fields;
    my($description_field) = shift;
    my($query) = "select distinct $key_field, $description_field from $object";
    my(%lookup_hash);
    my(@row);
    my($value);
    my($label);

    map {
	s/^\s*//g;
	s/\s*$//g;
	if ($object eq $_) {
	    return undef;
	}
    } split(',',$cgi_param->{'disable_lookup'});
    if (defined($key_field) &&
	$key_field !~ /^\s*$/ &&
	defined($description_field) &&
	$description_field !~ /^\s*$/ &&
	defined($object) &&
	$object !~ /^\s*$/) {
	$X->Sql($query);
	while(@row = $X->NextRow()) {
	    if ($X->Regular_Row()) {
		foreach $value (@row) {
		    $value =~ s/^\s*//g;
		    $value =~ s/\s*$//g;
		}
		$value = join("\t",@row[0..$num_key_field]);
		$label = join("\t",@row[$num_key_field+1..$#row]);
		if ($value !~ /^\s*$/) {
		    if ($label !~ /^\s*$/) {
			$lookup_hash{$value} = $label;
		    } else {
			$lookup_hash{$value} = $value;
		    }
		}
	    }
	}
	while ($X->More_Results()) {}
    }
    return %lookup_hash;
}

#
# %lookup_hash = get_range($X,$cgi_param,$object,$field);
#

sub get_range {
    my($X) = shift;
    my($cgi_param) = shift;
    my($object) = shift;
    my($field) = shift;
    my($type) = shift;
    my($quote) = 0;
    my($query) = "select distinct $field from $object";
    my(%lookup_hash);
    my(@row);
    my($key);

    map {
	s/^\s*//g;
	s/\s*$//g;
	if ($object eq $_) {
	    return undef;
	}
    } split(',',$cgi_param->{'disable_lookup'});
    if ($type =~ /char/ ||
	$type =~ /text/ ||
	$type =~ /datetime/ ) {
	$quote = 1;
    }
    if (defined($field) &&
	$field !~ /^\s*$/ &&
	defined($object) &&
	$object !~ /^\s*$/) {
	$X->Sql($query);
	while(@row = $X->NextRow()) {
	    if ($X->Regular_Row()) {
		$row[0] =~ s/^\s*//g;
		$row[0] =~ s/\s*$//g;
		$key = $row[0];
		if ($quote) {
		    $key =~ s/\'/\'\'/g;	# Quote quotes
		    $key = "'$key'";
		}
		if ($row[0] !~ /^\s*$/ ) {
		    $lookup_hash{$key} = $row[0];
		}
	    }
	}
	while ($X->More_Results()) {}
    }
    return %lookup_hash;
}

sub html_file_include {
    my($filearg) = shift;
    my($rootdir) = $ENV{'DOCUMENT_ROOT'};
    my($filename) = "$rootdir$filearg";
    my($file);

    if (-e $filename && -r $filename) {
	open(HTML_INCLUDE_FILE,$filename);
	while(<HTML_INCLUDE_FILE>) {
	    $file .= $_;
	}
	close(HTML_INCLUDE_FILE);
    }
    return $file;
}

#
# $cgi_param = PQEntry($cgi_query);
#

sub PQEntry {
    my($query) = shift;
    my($pqdebug) = $query->param('pqdebug');
    # Get pq database parameters or set defaults
    my($pq_server) = $query->param('pqweb_server');
    my($pq_database) = $query->param('pqweb_database') || 'pqweb';
    my($pq_username) = $query->param('pqweb_username');
    my($pq_password) = $query->param('pqweb_password');
    my($pqweb_entry) = $query->param('pqweb_entry');

    if (defined($pqweb_entry)) {
	# Get (open) connection to pqweb database
	( $PQ = RDBAL::Connect($pq_username, $pq_password,
			       $pq_server,
			       $query->param('server_type')) )
	    or return undef;
	( $PQ->UseDatabase($pq_database) )
	    or return undef;
    }

     # Get pq parameters
    return get_pq_parameters($PQ,$pqweb_entry,$query,$pqdebug);
}

sub get_pq_parameters {
    my($PQ) = shift;
    my($pqweb_entry) = shift;
    my($query) = shift;
    my($pqdebug) = $query->param('pqdebug');
    #----------------------------------------------------
    my(@passthru) = (
		     'pqdebug',
		     'server',
		     'database',
		     'table',
		     'username',
		     'password',
		     'server_type',
		     'subedit_tables',
		     'button_subedit',
		     'begin_html_include',
		     'middle_html_include',
		     'end_html_include',
		     'disable_lookup',
		     'no_schemacache' );

    my($helppage) = $query->param('helppage');
    my($nondisplay) = $query->param('nondisplay');
    my($labels) = $query->param('labels');
    my(%web_value);
    my(@field);
    my(@value);
    my($parameter);
    my($i);
    my($result_type, $accumulate);

    if (defined($query->param('pqweb_entry'))) {
	my($command) = "select result_enum, helppage, accumulate_keys ".
	    "from pqweb where pq='$pqweb_entry'";
	my(@row);
	$PQ->Sql($command);
	($result_type, $helppage, $accumulate) = $PQ->NextRow();
	$helppage =~ s/^\s*//g;
	$helppage =~ s/\s*$//g;
	while ($PQ->More_Results()) {}
	$command = "select field_name, label from pq_labels ".
	    "where pq='$pqweb_entry'";
	$PQ->Sql($command);
	while(@row = $PQ->NextRow()) {
	    if ($PQ->Regular_Row()) {
		$row[0] =~ s/^\s*//g;
		$row[0] =~ s/\s*$//g;
		$row[1] =~ s/^\s*//g;
		$row[1] =~ s/\s*$//g;
		if (defined($labels)) {
		    $labels .= ','."$row[0];$row[1]";
		} else {
		    $labels = "$row[0];$row[1]";
		}
	    }
	}
	while ($PQ->More_Results()) {}
	$command = "select noshow_field from pq_noshow ".
	    "where pq='$pqweb_entry'";
	$PQ->Sql($command);
	while(@row = $PQ->NextRow()) {
	    if ($PQ->Regular_Row()) {
		$row[0] =~ s/^\s*//g;
		$row[0] =~ s/\s*$//g;
		if (defined($nondisplay)) {
		    $nondisplay .= ','.$row[0];
		} else {
		    $nondisplay = $row[0];
		}
	    }
	}
	while ($PQ->More_Results()) {}
	$command = "select element_description, web_property, web_value ".
	    "from pq_webvalues a, web_elements b ".
		"where pq='$pqweb_entry' and a.web_elements=b.web_elements";
	$PQ->Sql($command);
	while(@row = $PQ->NextRow()) {
	    if ($PQ->Regular_Row()) {
		$row[0] =~ s/^\s*//g;
		$row[0] =~ s/\s*$//g;
		$row[1] =~ s/^\s*//g;
		$row[1] =~ s/\s*$//g;
		$row[2] =~ s/^\s*//g;
		$row[2] =~ s/\s*$//g;
		$web_value{"$row[0]_$row[1]"} = $row[2];
	    }
	}
	while ($PQ->More_Results()) {}
    }    
    my(%cgi_param) = (
		      'helppage' => $helppage,
		      'labels' => $labels,
		      'nondisplay' => $nondisplay);

    map {
	$cgi_param{$_} = $query->param($_);
    } @passthru;
    my($web_property);
    foreach $web_property (keys %web_value) {
	$cgi_param{"web_$web_property"} = $web_value{$web_property};
    }
    map {
	if (/^web_/) {
	    $cgi_param{"$_"} = $query->param("$_");
	}
	if (/^pq_.*_______________/) {
	    $parameter = $_;
	    @value = split("\t",$query->param($_));
	    $parameter =~ s/^pq_//;
	    @field = split('_______________',$parameter);
	    for ($i = 0; $i <= $#field;$i++) {
		$query->param("pq_".$field[$i],$value[$i]);
	    }
	    $query->delete("pq_$parameter");
	}
    } $query->param;
    if (!defined($cgi_param{'web_textarea_columns'})) {
	$cgi_param{'web_textarea_columns'} = 61;
    }
    if (!defined($cgi_param{'web_textarea_rows'})) {
	$cgi_param{'web_textarea_rows'} = 2;
    }
    return \%cgi_param;
}

sub PQLogin {
    my($query) = shift;
    my($cgi_param) = shift;
    my($self_url) = $query->self_url;
    my($body_bgcolor) = (defined($cgi_param->{'web_body_bgcolor'})) ?
	$cgi_param->{'web_body_bgcolor'} : 'teal';
    my($javascript) = <<"EndJavaScript";
    function submit_login() {
	formObj = document.PQLogin;
	if ( formObj.server.value == "" || 
	    formObj.database.value == "" ||
	    formObj.table.value == "" ||
	    formObj.username.value == "" ||
	    formObj.password.value == "" ) {
	    alert("Please enter all login information");
	    return false;
	}
    }
EndJavaScript

    if (!$cgi_param->{'pqdebug'}) {
	$self_url =~ s/\?.*$//;
    }
    if (defined($query->param('password'))) {
	$cgi_param->{'password'} = $query->param('password');
    }
    if (defined($cgi_param->{'server'}) &&
	defined($cgi_param->{'database'}) &&
	defined($cgi_param->{'table'}) &&
	defined($cgi_param->{'username'}) &&
	defined($cgi_param->{'password'})) {
	return 1;
    }
    # Output HTML
#    if ($query->request_method() eq 'GET' || $query->user_agent() !~ /MSIE/ ||
#	$query->server_software =~ /IIS/) {
	print $query->header(-type => 'text/html',
			     -status => '200 OK');
#    }
    print "\n";
    print $query->start_html(-title => 'PQ Login',
				 -author => 'brian@ibc.wustl.edu',
				 -script => $javascript,
			     -text => 'white',
				 -BGCOLOR => $body_bgcolor);
    print "\n";
    print '<H1 ALIGN="CENTER">PQ Login</H1>'."\n";
    print $query->start_form(-method => 'POST',
			     -name =>  "PQLogin",
			     -onSubmit => "return submit_login()",
			     -action => $self_url);
    print "\n";
    print '<TABLE BORDER="3" ALIGN="CENTER" bordercolordark="#000000" CELLSPACING="0">'."\n\t<TR>\n\t\t<TD>";
    print "<BIG>Server: </BIG></TD>\n\t\t<TD>";
    if (defined($cgi_param->{'server'})) {
	print "<B><I>$cgi_param->{'server'}</I></B>";
    } else {
	print $query->textfield(-name => 'server',
				-default => 'ibc_sybase',
				-size => 50,
				-style => 'background-color: white',
				-BGCOLOR => 'white',
				-maxlength => 255);
    }
    print "</TD>\n\t</TR>\n\t<TR>\n\t\t<TD>";
    print "<BIG>Database: </BIG></TD>\n\t\t<TD>";
    if (defined($cgi_param->{'database'})) {
	print "<B><I>$cgi_param->{'database'}</I></B>";
    } else {
	print $query->textfield(-name => 'database',
				-default => 'master',
				-size => 50,
				-style => 'background-color: white',
				-maxlength => 255);
    }
    print "</TD>\n\t</TR>\n\t<TR>\n\t\t<TD>";
    print "<BIG>Table: </BIG></TD>\n\t\t<TD>";
    if (defined($cgi_param->{'table'})) {
	print "<B><I>$cgi_param->{'table'}</I></B>";
    } else {
	print $query->textfield(-name => 'table',
				-default => '',
				-size => 50,
				-style => 'background-color: white',
				-maxlength => 255);
    }
    print "</TD>\n\t</TR>\n\t<TR>\n\t\t<TD>";
    print "<BIG>Username: </BIG></TD>\n\t\t<TD>";
    if (defined($cgi_param->{'username'})) {
	print "<B><I>$cgi_param->{'username'}</I></B>";
    } else {
	print $query->textfield(-name => 'username',
				-default => 'guest',
				-size => 50,
				-style => 'background-color: white',
				-maxlength => 255);
    }
    print "</TD>\n\t</TR>\n\t<TR>\n\t\t<TD>";
    print "<BIG>Password: </BIG></TD>\n\t\t<TD>";
    if (defined($cgi_param->{'password'})) {
	print "<B><I>$cgi_param->{'password'}</I></B>";
    } else {
	print $query->password_field(-name => 'password',
				     -default => '',
				     -size => 50,
				     -style => 'background-color: white',
				     -maxlength => 255);
    }
    print "</TD>\n\t</TR>\n</TABLE>\n";
    print '<TABLE BORDER="0" ALIGN="CENTER" CELLSPACING="0">'."\n\t<TR>\n\t\t<TD>";
    print 
	$query->submit(-name => 'Login   ',
		       -style => 'background-color: gray') .
    " \n" .
    $query->reset(-name => 'Reset     ',
		  -style => 'background-color: gray');
    print "</TD>\n\t</TR>\n</TABLE>\n";
    print PQHidden_Parameters($query,$cgi_param);
    print "\n" . $query->end_form;
    print "\n" . $query->end_html;
    return 0;
}

sub Login_Error {
    my($query) = shift;
    my($cgi_param) = shift;

#    if ($query->request_method() eq 'GET' || $query->user_agent() !~ /MSIE/ ||
#	$query->server_software =~ /IIS/) {
	print $query->header(-type => 'text/html',
			     -status => '200 OK');
#    }
    print "\n";
    print $query->start_html(-title => "PQ Login",
			     -author => 'brian@ibc.wustl.edu',
			     -BGCOLOR => 'green');
    print "\n";
    print '<H1 ALIGN="CENTER">Login Error</H1>'."\n";
    print "<BIG><BIG>Unable to login to server: <B>",
    $cgi_param->{'server'},'</B>, database: <B>',
    $cgi_param->{'database'},'</B> as user: <B>',
    $cgi_param->{'username'},"</B></BIG></BIG>\n";
    print $query->end_html;
}

sub PQHidden_Parameters {
    my($cgi_query) = shift;
    my($cgi_param) = shift;
    my($output_form);
    my($param_name);


    foreach $param_name (keys %{$cgi_param}) {
	if (defined($param_name) &&
	    defined($cgi_param->{$param_name})) {
	    $output_form .= $cgi_query->hidden($param_name,
					       $cgi_param->{$param_name});
	    $output_form .= "\n";
	}
    }
    $output_form .= "\n";
    return $output_form;
}

1;
!NO!SUBS!

close OUT or die "Can't close $file.cgi: $!";
chmod 0755, "$file.cgi" or die "Can't reset permissions for $file.cgi: $!\n";
exec("$Config{'eunicefix'} $file.cgi") if $Config{'eunicefix'} ne ':';
