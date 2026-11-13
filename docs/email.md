# Email

GLPI sends email for ticket notifications, follow-ups, password resets and
alerts, and can also receive email to create and update tickets. Nothing is
configured by default.

Unlike the database connection, mail is not a chart setting. GLPI keeps its
mail configuration in the database and edits it in the UI, and it stores the
SMTP password encrypted with `glpicrypt.key`. No value in this chart and no
Kubernetes Secret is involved.

## Sending

1. Under Setup > Notifications, turn on "Enable notifications" and the email
   notifications switch.
2. Open the email notifications configuration on the same page and fill in:

| Field | Value |
|-------|-------|
| Way of sending emails | `SMTP`, `SMTP+TLS` (port 587, STARTTLS) or `SMTP+SSL` (port 465) |
| SMTP host and port | The mail server |
| Login and password | The account GLPI sends as, if the server requires one |
| Check certificate | On, unless the server uses a certificate the image does not trust |
| Email sender address | An address the server allows that account to send as |

3. Save, then use "Send a test email to the administrator". It reports any
   error the mail server returned.

Notes:

- If "PHP" is offered as a way of sending, do not choose it. That mode hands
  mail to a local sendmail program, and the image has none.
- The sender's domain should have SPF and DKIM records for the server, or the
  mail is likely to be marked as spam.
- GLPI does not send at once. Notifications are queued and sent by the
  `queuednotification` automatic action, which the chart's `cron` container
  runs. With `cron.enabled: false` nothing is sent unless something else runs
  `front/cron.php`.

### Through an in-cluster relay

When a cluster runs an SMTP relay for all its applications, GLPI needs no
credentials of its own: choose `SMTP`, set the host to the relay's Service
name (for example `smtp-relay.mail.svc.cluster.local`) and port 25, and leave
the login empty. If the relay presents a certificate from a private CA that
the image does not trust, turn "Check certificate" off. Inside the cluster
that is usually acceptable. Across a network it is not.

## Receiving

Mail receivers (Setup > Receivers) let GLPI poll an IMAP or POP mailbox and
turn messages into tickets and follow-ups. The `mailgate` automatic action
does the polling, again from the `cron` container. The mailbox password is
stored encrypted in the database like the SMTP one.

## Troubleshooting

Mail activity and errors go to GLPI's own log files on the data volume:

```console
kubectl -n glpi exec deploy/desk-glpi -c glpi -- tail -n 50 /var/glpi/logs/mail-error.log
kubectl -n glpi exec deploy/desk-glpi -c glpi -- tail -n 50 /var/glpi/logs/cron.log
```

The queue itself is visible under Administration > Notification queue, and
the state of each automatic action under Setup > Automatic actions.

Links in notification emails are built from GLPI's `url_base` setting, which
the chart sets from `glpi.url` on every start.
