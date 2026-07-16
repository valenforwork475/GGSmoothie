# Staff login

## Cashier

- Create the account from Back Office; the system assigns `GG001`, `GG002`, and so on automatically.
- The initial credential is a six-digit numeric PIN.
- Sign in to POS with the employee code and PIN. A personal email address is not required.
- After five consecutive failed attempts, sign-in is temporarily blocked for 15 minutes.

## Manager and Owner

- Use a real email address and a password of at least eight characters.
- Sign in to Back Office with that email address. Cashier accounts are rejected by Back Office.
- The login page asks for an email, sends a verified recovery link, and opens the Back Office password-reset form from that link.

## Administration

- Owner/Manager can deactivate an account immediately.
- Owner/Manager can reset a Cashier PIN or a Manager/Owner password from the staff table.
- Login attempts are stored in `staff_login_events`; direct anonymous table access is denied.
- Internal Cashier authentication emails are implementation details and are not shown to staff.
