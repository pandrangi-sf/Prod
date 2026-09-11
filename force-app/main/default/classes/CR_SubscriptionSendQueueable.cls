public with sharing class CR_SubscriptionSendQueueable implements Queueable {

    private Id subscriptionId;

    // Cap rows pulled for the CSV attachment so heap/email stay bounded; larger
    // sets should use the full export feature instead.
    @TestVisible private static Integer csvRowCap = 20000;
    // Cap dashboard components rendered per email so the body/attachments stay bounded.
    @TestVisible private static Integer maxDashboardComponents = 12;

    public CR_SubscriptionSendQueueable(Id subscriptionId) {
        this.subscriptionId = subscriptionId;
    }

    public void execute(QueueableContext context) {
        CR_Subscription__c sub;
        try {
            sub = [
                SELECT Id, Name, Report_Definition__c, Dashboard__c,
                    Include_HTML_Table__c, Include_CSV_Attachment__c, Max_Inline_Rows__c,
                    Send_If_Empty__c, Filter_Override_JSON__c
                FROM CR_Subscription__c
                WHERE Id = :subscriptionId
                LIMIT 1
            ];
        } catch (Exception e) {
            return; // subscription was deleted before the job ran; nothing to do
        }

        try {
            // Fail soft on a malformed filter override. An invalid override reaching
            // the query engine here either NPEs or throws an AuraHandledException —
            // and AuraHandledException is uncatchable off the Aura stack, which would
            // kill the job before mark() runs and leave the status stale. Structural
            // validation never throws, so we surface a clean Failed instead. (Saves
            // are validated up front in CR_SubscriptionService; this guards data saved
            // before that check existed.)
            List<String> filterErrors = CR_QueryEngine.validateOverrideFiltersStructural(sub.Filter_Override_JSON__c);
            if (!filterErrors.isEmpty()) {
                mark(sub, 'Failed', 'Invalid filter override: ' + String.join(filterErrors, ' '));
                return;
            }

            List<String> toAddresses = CR_GroupResolver.resolveEmails([
                SELECT Recipient_Type__c, User__c, User__r.Email, Group_Id__c, Email__c
                FROM CR_Subscription_Recipient__c
                WHERE Subscription__c = :sub.Id
            ]);
            if (toAddresses.isEmpty()) {
                mark(sub, 'Failed', 'No deliverable recipients (no active user emails / groups resolved).');
                return;
            }

            Rendered content;
            String subject;
            if (sub.Dashboard__c != null) {
                Dashboard__c d = [SELECT Id, Name, Broadcast_Safe__c FROM Dashboard__c WHERE Id = :sub.Dashboard__c LIMIT 1];
                if (d.Broadcast_Safe__c != true) {
                    mark(sub, 'Failed', 'Dashboard "' + d.Name + '" is not marked Broadcast Safe; refusing to send.');
                    return;
                }
                content = renderDashboard(sub, d);
                subject = 'Vital Reports: ' + d.Name;
            } else if (sub.Report_Definition__c != null) {
                Report_Definition__c rd = [SELECT Id, Name, Broadcast_Safe__c FROM Report_Definition__c WHERE Id = :sub.Report_Definition__c LIMIT 1];
                if (rd.Broadcast_Safe__c != true) {
                    mark(sub, 'Failed', 'Report "' + rd.Name + '" is not marked Broadcast Safe; refusing to send.');
                    return;
                }
                content = renderReport(sub, rd);
                subject = 'Vital Reports: ' + rd.Name;
            } else {
                mark(sub, 'Failed', 'No report or dashboard is linked to this subscription.');
                return;
            }

            if (content.totalRows == 0 && sub.Send_If_Empty__c != true) {
                mark(sub, 'No Data', 'Nothing to send (no rows); skipped because Send If Empty is off.');
                return;
            }

            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            for (String addr : toAddresses) {
                Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
                msg.setToAddresses(new List<String>{ addr });
                msg.setSubject(subject);
                msg.setHtmlBody(content.html);
                msg.setSaveAsActivity(false);
                if (!content.attachments.isEmpty()) {
                    msg.setFileAttachments(content.attachments);
                }
                emails.add(msg);
            }
            // allOrNone=false: the platform returns a per-message result instead of
            // throwing, so a partial bounce (e.g. daily email limit, bad address)
            // is reported here rather than swallowed. Marking 'Success' on every
            // send — including ones the platform rejected — used to hide this.
            Messaging.SendEmailResult[] results = Messaging.sendEmail(emails, false);
            Integer sent = 0;
            String firstError = null;
            for (Messaging.SendEmailResult r : results) {
                if (r.isSuccess()) {
                    sent++;
                } else if (firstError == null && !r.getErrors().isEmpty()) {
                    firstError = String.valueOf(r.getErrors()[0].getStatusCode()) + ': ' + r.getErrors()[0].getMessage();
                }
            }
            Integer failed = emails.size() - sent;
            if (sent == 0) {
                mark(sub, 'Failed', 'All ' + emails.size() + ' message(s) were rejected by the platform'
                    + (firstError == null ? '.' : ' — ' + firstError));
            } else if (failed > 0) {
                mark(sub, 'Partial', 'Sent ' + sent + ' of ' + emails.size() + ' message(s); ' + failed
                    + ' rejected' + (firstError == null ? '' : ' (' + firstError + ')') + '. ' + content.totalRows + ' rows.');
            } else {
                mark(sub, 'Success', 'Sent to ' + sent + ' recipient(s); ' + content.totalRows + ' rows.');
            }
        } catch (Exception ex) {
            mark(sub, 'Failed', ex.getMessage());
        }
    }

    private class Rendered {
        String html = '';
        List<Messaging.EmailFileAttachment> attachments = new List<Messaging.EmailFileAttachment>();
        Integer totalRows = 0;
    }

    private Rendered renderReport(CR_Subscription__c sub, Report_Definition__c rd) {
        Integer maxInline = inlineCap(sub);
        Integer fetchRows = (sub.Include_CSV_Attachment__c == true) ? Math.max(maxInline, csvRowCap) : maxInline;
        CR_Types.QueryResult result = CR_QueryEngine.runReportById(sub.Report_Definition__c, null, fetchRows, sub.Filter_Override_JSON__c);

        Rendered out = new Rendered();
        out.totalRows = rowCount(result);
        out.html = header(rd.Name) + sectionHtml(sub, rd.Name, result, maxInline);
        if (sub.Include_CSV_Attachment__c == true && result != null) {
            out.attachments.add(csvAttachment(rd.Name, result));
        }
        return out;
    }

    private Rendered renderDashboard(CR_Subscription__c sub, Dashboard__c d) {
        Integer maxInline = inlineCap(sub);
        List<Dashboard_Component__c> components = [
            SELECT Name, Report_Definition__c, Report_Definition__r.Name
            FROM Dashboard_Component__c
            WHERE Dashboard__c = :d.Id AND Report_Definition__c != null
            ORDER BY Position_Y__c, Position_X__c
            LIMIT :maxDashboardComponents
        ];

        Rendered out = new Rendered();
        out.html = header(d.Name);
        if (components.isEmpty()) {
            out.html += '<p style="font-family:Arial,sans-serif;font-size:12px;color:#54698d;">This dashboard has no report-backed components to deliver.</p>';
            return out;
        }
        for (Dashboard_Component__c component : components) {
            String title = (component.Report_Definition__r != null && component.Report_Definition__r.Name != null)
                ? component.Report_Definition__r.Name
                : component.Name;
            CR_Types.QueryResult result = CR_QueryEngine.runReportById(
                component.Report_Definition__c, null, maxInline, sub.Filter_Override_JSON__c
            );
            out.totalRows += rowCount(result);
            out.html += sectionHtml(sub, title, result, maxInline);
            if (sub.Include_CSV_Attachment__c == true && result != null) {
                out.attachments.add(csvAttachment(title, result));
            }
        }
        return out;
    }

    private static Integer rowCount(CR_Types.QueryResult result) {
        return (result == null || result.rows == null) ? 0 : result.rows.size();
    }

    private static Integer inlineCap(CR_Subscription__c sub) {
        Integer m = (sub.Max_Inline_Rows__c == null) ? 100 : sub.Max_Inline_Rows__c.intValue();
        return m < 1 ? 100 : m;
    }

    private Messaging.EmailFileAttachment csvAttachment(String name, CR_Types.QueryResult result) {
        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        att.setFileName(safeFileName(name) + '.csv');
        att.setBody(Blob.valueOf(CR_CsvUtil.toCsvString(result.columns, result.rows, csvRowCap)));
        att.setContentType('text/csv');
        return att;
    }

    private static String header(String assetName) {
        return '<p style="font-family:Arial,sans-serif;font-size:13px;">Automated delivery from <strong>Vital Reports</strong> &mdash; <strong>'
            + htmlEscape(assetName) + '</strong>.</p>';
    }

    private static String sectionHtml(CR_Subscription__c sub, String title, CR_Types.QueryResult result, Integer maxInline) {
        Integer rows = rowCount(result);
        String html = '<p style="font-family:Arial,sans-serif;font-size:13px;margin-top:14px;"><strong>'
            + htmlEscape(title) + '</strong> &mdash; ' + rows + ' row' + (rows == 1 ? '' : 's') + '.</p>';

        if (sub.Include_HTML_Table__c == true && result != null && result.columns != null) {
            html += '<table cellpadding="6" cellspacing="0" style="border-collapse:collapse;font-family:Arial,sans-serif;font-size:12px;border:1px solid #d8dde6;">';
            html += '<thead><tr style="background:#f3f6f9;">';
            for (CR_Types.ColumnInfo column : result.columns) {
                html += '<th align="left" style="border:1px solid #d8dde6;padding:6px;">' + htmlEscape(column.label) + '</th>';
            }
            html += '</tr></thead><tbody>';
            Integer shown = 0;
            if (result.rows != null) {
                for (Map<String, Object> row : result.rows) {
                    if (shown >= maxInline) {
                        break;
                    }
                    html += '<tr>';
                    for (CR_Types.ColumnInfo column : result.columns) {
                        html += '<td style="border:1px solid #d8dde6;padding:6px;">'
                            + htmlEscape(String.valueOf(row.get(column.key))) + '</td>';
                    }
                    html += '</tr>';
                    shown++;
                }
            }
            html += '</tbody></table>';
            if (rows > shown) {
                String tail = (sub.Include_CSV_Attachment__c == true)
                    ? ' See the attached CSV for the full set.'
                    : ' Remaining rows were truncated.';
                html += '<p style="font-family:Arial,sans-serif;font-size:12px;color:#54698d;">&hellip; '
                    + (rows - shown) + ' more rows.' + tail + '</p>';
            }
        }
        return html;
    }

    private static String htmlEscape(String value) {
        if (value == null) {
            return '';
        }
        return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;');
    }

    private static String safeFileName(String name) {
        String base = (name == null) ? 'report' : name.replaceAll('[^A-Za-z0-9_ -]', '');
        return String.isBlank(base) ? 'report' : base;
    }

    private static void mark(CR_Subscription__c sub, String status, String message) {
        sub.Last_Run_At__c = System.now();
        sub.Last_Status__c = status;
        sub.Last_Message__c = (message != null && message.length() > 255) ? message.substring(0, 255) : message;
        update sub;
    }
}