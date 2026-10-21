// Forward matching Gmail messages, once each. Runs inside Google Apps Script on
// a time trigger, replacing the forward step of tasks/email-forwarder.md (Claude's
// Gmail connector now requires per-call approval, so headless runs can't forward).
//
// Same rules and dedup labels as the task, so the two can overlap safely: a
// message carrying a rule's label is never forwarded again by either.
//
// Setup: see README.md in this folder.

const RULES = [
  {
    query: 'to:(tech-craftsmanship@kasa.com) pragmatic',
    to: 'arcgaborbot@gmail.com',
    label: 'scheduler/fwd-arcgaborbot',
  },
  {
    query: 'from:niveus has:attachment',
    to: 'arcpaperless@gmail.com',
    label: 'scheduler/fwd-arcpaperless',
  },
];

const WINDOW = 'newer_than:3d';
const MAX_PER_RULE = 25;

function forwardMatching() {
  const labelIds = resolveLabelIds_();
  const summary = [];

  for (const rule of RULES) {
    const labelId = labelIds[rule.label];
    // Search syntax wants the label name with '/' as '-'; IDs don't work there.
    const q = `${rule.query} -label:${rule.label.replace(/\//g, '-')} ${WINDOW} -in:sent -in:trash -in:spam -from:me`;
    const ids = listMessageIds_(q);

    if (ids.length > MAX_PER_RULE) {
      // A burst this large is more likely a bad match than real mail.
      throw new Error(`${rule.label}: ${ids.length} candidates exceeds cap ${MAX_PER_RULE}; nothing forwarded`);
    }

    for (const id of ids) {
      GmailApp.getMessageById(id).forward(rule.to);
      labelMessage_(id, labelId);
    }
    summary.push(`${rule.label}: ${ids.length}`);
  }

  console.log(`forwarded ${summary.join(', ')}`);
}

// Message-level search: a thread can hold matching and non-matching messages,
// and the forwarded copy joins the original's thread.
function listMessageIds_(q) {
  const ids = [];
  let pageToken;
  do {
    const res = Gmail.Users.Messages.list('me', { q, maxResults: 100, pageToken });
    (res.messages || []).forEach((m) => ids.push(m.id));
    pageToken = res.nextPageToken;
  } while (pageToken);
  return ids;
}

function labelMessage_(id, labelId) {
  const body = { addLabelIds: [labelId] };
  try {
    Gmail.Users.Messages.modify(body, 'me', id);
  } catch (e) {
    try {
      Gmail.Users.Messages.modify(body, 'me', id);
    } catch (e2) {
      // Already forwarded but unlabeled: stop so the next run can't send a
      // second copy before someone looks. The failed execution emails you.
      throw new Error(`forwarded ${id} but could not label it; label it by hand before the next run: ${e2}`);
    }
  }
}

function resolveLabelIds_() {
  const existing = {};
  (Gmail.Users.Labels.list('me').labels || []).forEach((l) => (existing[l.name] = l.id));
  const ids = {};
  for (const rule of RULES) {
    ids[rule.label] = existing[rule.label] || Gmail.Users.Labels.create({ name: rule.label }, 'me').id;
  }
  return ids;
}

// Run once by hand to install the daily trigger. Apps Script fires somewhere
// in the 06:00 hour (manifest time zone), so it finishes before the Claude task
// at 07:05, which then finds everything labeled.
function installTrigger() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'forwardMatching')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('forwardMatching').timeBased().everyDays(1).atHour(6).create();
}

// Lists what would be forwarded without sending anything.
function dryRun() {
  for (const rule of RULES) {
    const q = `${rule.query} -label:${rule.label.replace(/\//g, '-')} ${WINDOW} -in:sent -in:trash -in:spam -from:me`;
    const ids = listMessageIds_(q);
    const subjects = ids.map((id) => GmailApp.getMessageById(id).getSubject());
    console.log(`${rule.label} -> ${rule.to}: ${ids.length} ${JSON.stringify(subjects)}`);
  }
}
