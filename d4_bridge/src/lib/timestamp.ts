// Local Timestamp shim — replaces firebase/firestore's `Timestamp` so the app
// carries no Firebase dependency. The Supabase seams (events/orgs/tickets) map
// Postgres timestamptz strings into this via toTs(); the ~20 views read it as
// `.toDate()` / `.seconds`. The API surface mirrors the subset of Firebase's
// Timestamp the app actually uses, so the swap is a pure import change.

export class Timestamp {
  readonly seconds: number;
  readonly nanoseconds: number;

  constructor(seconds: number, nanoseconds = 0) {
    this.seconds = seconds;
    this.nanoseconds = nanoseconds;
  }

  static fromDate(date: Date): Timestamp {
    return Timestamp.fromMillis(date.getTime());
  }

  static fromMillis(ms: number): Timestamp {
    const seconds = Math.floor(ms / 1000);
    const nanoseconds = Math.floor((ms - seconds * 1000) * 1e6);
    return new Timestamp(seconds, nanoseconds);
  }

  static now(): Timestamp {
    return Timestamp.fromMillis(Date.now());
  }

  toDate(): Date {
    return new Date(this.toMillis());
  }

  toMillis(): number {
    return this.seconds * 1000 + Math.floor(this.nanoseconds / 1e6);
  }

  valueOf(): number {
    return this.toMillis();
  }
}
