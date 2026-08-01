# Feature Specification: Checkout

We need customers to complete checkout without leaving the cart page.

### User Story 1 - Pay with a saved card (Priority: P1)

As a returning customer, I want to pay with a saved card.

- **Given** a signed-in customer with a saved card
- **When** they confirm the order
- **Then** the payment is captured without re-entering card details

### User Story 2 - Apply a promo code (Priority: P2)

As a customer, I want to apply a promo code at checkout.

- **Given** a customer with a valid promo code
- **When** they enter it at checkout
- **Then** the discount is applied to the order total
