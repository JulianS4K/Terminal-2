# Security Specification for Exos

## Data Invariants
1. A Ticket must belong to a valid Event.
2. A Ticket owner can only be changed via a valid Transfer process or initial purchase.
3. Rotating barcodes are simulated; the `barcodeValue` should be updated periodically by a trusted client or system, but restricted to ensure users don't spoof others.
4. An Event organizer is the only one who can modify Event details.

## The Dirty Dozen (Potential Payloads)
1. Someone trying to change the `ownerId` of a ticket directly.
2. Someone trying to set `price` of an event to negative.
3. Someone trying to set `ticketsSold` > `totalTickets`.
4. Someone trying to read all tickets in the system without owning them.
5. Someone trying to update someone else's user profile.
6. Someone trying to cancel a transfer they are not part of.
7. Someone trying to complete a transfer without being the receiver.
8. Someone trying to change the `organizerId` of an event.
9. Someone trying to inject a 1MB string into the `barcodeValue`.
10. Someone trying to purchase a ticket for an event that is sold out.
11. Someone trying to spoof their `emailVerified` status.
12. Someone trying to reuse a used ticket.

## Test Runner (Internal Logic)
I will ensure the rules handle these cases.
