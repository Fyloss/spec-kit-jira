# Feature Specification: Billing Invoices
<!-- speckit-jira spec=3333333333333333 creating -->

We need to let customers export their invoices.

### User Story 1 - Export a single invoice (Priority: P1)

As a customer, I want to export one invoice as a PDF.

- **Given** a signed-in customer viewing an invoice
- **When** they choose Export
- **Then** a PDF download starts

### User Story 2 - Export a date range (Priority: P2)

As a customer, I want to export every invoice in a date range.

- **Given** a signed-in customer on the invoices page
- **When** they pick a start and end date and choose Export
- **Then** a zip of PDFs download starts

### User Story 3 - Export is unavailable during maintenance (Priority: P3)

As a customer, I want a clear message when export is temporarily unavailable.

- **Given** the export service is in maintenance mode
- **When** a customer chooses Export
- **Then** they see a message explaining when to retry
