import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/service_status.dart';

void main() {
  test('running is explicit and unavailable never appears active', () {
    const running = ServiceStatus(ServiceState.running);
    const php = ServiceStatus(ServiceState.unavailable);
    expect(running.isRunning, isTrue);
    expect(running.label, 'Running');
    expect(php.isRunning, isFalse);
    expect(php.label, 'Unavailable');
  });

  test('only stopped and failed services can be started', () {
    expect(const ServiceStatus(ServiceState.stopped).canStart, isTrue);
    expect(const ServiceStatus(ServiceState.error).canStart, isTrue);
    expect(const ServiceStatus(ServiceState.running).canStart, isFalse);
    expect(const ServiceStatus(ServiceState.starting).canStart, isFalse);
  });
}
