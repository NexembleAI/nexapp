import 'models/tracking_models.dart';

/// CRM customers + assigned leads, read from Odoo at runtime via the
/// platform (§2.2) — never from the client directly. Backend arrives in
/// Phase 2/3.
abstract class CustomersRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late CustomersRepository instance;

  /// Customers tied to the current user's assigned leads (picker list).
  Future<List<Customer>> myCustomers();

  /// The user's assigned leads for one customer (§3.3: tagging scope).
  Future<List<Lead>> leadsForCustomer(String customerId);
}
