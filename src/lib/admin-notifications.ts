export type AdminNotificationRow = Record<string, unknown>;

export type AdminNotificationMember = {
  id: string;
  source: string;
};

const businessSources = new Set(["notifications", "internal_notifications"]);

function value(row: AdminNotificationRow, key: string) {
  return String(row[key] ?? "").trim();
}

function truthy(input: unknown) {
  return input === true || String(input ?? "").toLowerCase() === "true";
}

function eventFamily(row: AdminNotificationRow) {
  const input = `${value(row, "type")} ${value(row, "title")} ${value(row, "message")} ${value(row, "body")}`.toLowerCase();
  if (/payout|release|liquid|liberad/.test(input)) return "payout_released";
  if (/booking_completed|code_verified|codigo|cierre/.test(input)) return "booking_completed";
  if (/payment|pago/.test(input)) return "payment";
  if (/booking|reserva/.test(input)) return "booking";
  return value(row, "type").toLowerCase() || "general";
}

function businessKey(row: AdminNotificationRow) {
  const suppliedKey = value(row, "dedupe_key");
  const user = value(row, "user_id");
  if (suppliedKey) return `${user}:${suppliedKey}`;

  const booking = value(row, "booking_id") || value(row, "related_booking_id") || value(row, "reference_id");
  const copy = `${value(row, "title")}|${value(row, "message") || value(row, "body")}`.toLowerCase();
  return `${user}:${booking}:${eventFamily(row)}:${booking ? "" : copy}`;
}

export function isBusinessNotification(row: AdminNotificationRow) {
  return businessSources.has(value(row, "source").toLowerCase());
}

export function isAdminNotificationRead(row: AdminNotificationRow) {
  return truthy(row.is_read) || value(row, "read_status").toLowerCase() === "read" || Boolean(row.admin_read_at);
}

export function isAdminNotificationArchived(row: AdminNotificationRow) {
  return truthy(row.is_archived) || Boolean(row.admin_archived_at);
}

export function isAdminNotificationDeleted(row: AdminNotificationRow) {
  return truthy(row.is_deleted) || Boolean(row.admin_deleted_at);
}

export function notificationMembers(row: AdminNotificationRow): AdminNotificationMember[] {
  const stored = row.__notification_members;
  if (Array.isArray(stored)) {
    return stored.filter((member): member is AdminNotificationMember => (
      Boolean(member)
      && typeof member === "object"
      && typeof (member as AdminNotificationMember).id === "string"
      && typeof (member as AdminNotificationMember).source === "string"
    ));
  }

  const id = value(row, "id");
  const source = value(row, "source");
  return id && source ? [{ id, source }] : [];
}

export function normalizeAdminNotificationRows<T extends AdminNotificationRow>(rows: T[]): T[] {
  const normalized: T[] = [];
  const grouped = new Map<string, T>();

  for (const original of rows) {
    if (!isBusinessNotification(original)) {
      normalized.push(original);
      continue;
    }

    const member = notificationMembers(original)[0];
    const key = businessKey(original);
    const current = grouped.get(key);

    if (!current) {
      const next = {
        ...original,
        __notification_members: member ? [member] : [],
      } as T;
      grouped.set(key, next);
      normalized.push(next);
      continue;
    }

    const members = notificationMembers(current);
    if (member && !members.some((item) => item.id === member.id && item.source === member.source)) {
      members.push(member);
    }
    (current as AdminNotificationRow).__notification_members = members;

    // A mirrored event is considered reviewed when either administrative copy was reviewed.
    if (isAdminNotificationRead(original)) {
      (current as AdminNotificationRow).is_read = true;
      (current as AdminNotificationRow).read_status = "read";
    }
  }

  return normalized;
}

export function countUnreadBusinessNotifications(rows: AdminNotificationRow[]) {
  return normalizeAdminNotificationRows(rows).filter((row) => (
    isBusinessNotification(row)
    && !isAdminNotificationRead(row)
    && !isAdminNotificationArchived(row)
    && !isAdminNotificationDeleted(row)
  )).length;
}
