import 'package:flutter_test/flutter_test.dart';
import 'package:pallsql/models/service_status.dart';

void main() {
  group('ServiceState', () {
    test('only running is treated as serving', () {
      expect(ServiceState.running.isRunning, isTrue);
      expect(ServiceState.starting.isRunning, isFalse);
      expect(ServiceState.stopping.isRunning, isFalse);
      expect(ServiceState.stopped.isRunning, isFalse);
      expect(ServiceState.error.isRunning, isFalse);
      expect(ServiceState.unavailable.isRunning, isFalse);
    });

    test('start and stop affordances follow the lifecycle', () {
      expect(ServiceState.stopped.canStart, isTrue);
      expect(ServiceState.error.canStart, isTrue);
      expect(ServiceState.running.canStart, isFalse);
      expect(ServiceState.stopped.canStop, isFalse);
      expect(ServiceState.running.canStop, isTrue);
      expect(ServiceState.starting.canStop, isTrue);
      expect(ServiceState.unavailable.canStart, isFalse);
      expect(ServiceState.unavailable.canStop, isFalse);
    });

    test('transitions are marked busy', () {
      expect(ServiceState.starting.isTransitional, isTrue);
      expect(ServiceState.stopping.isTransitional, isTrue);
      expect(ServiceState.running.isTransitional, isFalse);
    });

    test('labels are human readable', () {
      expect(ServiceState.stopped.label, 'Stopped');
      expect(ServiceState.running.label, 'Running');
      expect(ServiceState.unavailable.label, 'Unavailable');
    });
  });

  group('ServiceStatus', () {
    test('const constructors map to the right state', () {
      expect(const ServiceStatus.stopped().state, ServiceState.stopped);
      expect(const ServiceStatus.running().state, ServiceState.running);
      expect(const ServiceStatus.unavailable('no binary').state,
          ServiceState.unavailable);
      expect(const ServiceStatus.error('boom').message, 'boom');
    });

    test('copyWith keeps the message unless cleared', () {
      const ServiceStatus status = ServiceStatus.error('port busy');
      expect(status.copyWith(state: ServiceState.stopped).message, 'port busy');
      expect(
        status.copyWith(state: ServiceState.stopped, clearMessage: true).message,
        isNull,
      );
    });

    test('toString contains the state name', () {
      expect(const ServiceStatus.running().toString(), contains('running'));
    });
  });

  group('ServiceAggregate', () {
    ServiceAggregate build({
      ServiceState web = ServiceState.stopped,
      ServiceState php = ServiceState.unavailable,
      ServiceState database = ServiceState.running,
    }) {
      return ServiceAggregate(
        webServer: ServiceStatus(web),
        phpRuntime: ServiceStatus(php),
        database: ServiceStatus(database),
      );
    }

    test('start all is possible while the server is stopped', () {
      expect(build().canStartAll, isTrue);
      expect(build(web: ServiceState.running).canStartAll, isFalse);
    });

    test('busy services block bulk actions', () {
      final ServiceAggregate aggregate = build(web: ServiceState.starting);
      expect(aggregate.anyBusy, isTrue);
      expect(aggregate.canStartAll, isFalse);
      expect(aggregate.canStopAll, isFalse);
      expect(aggregate.overallState, ServiceState.starting);
    });

    test('an error anywhere is surfaced as the overall state', () {
      expect(
        build(web: ServiceState.error).overallState,
        ServiceState.error,
      );
      expect(build(web: ServiceState.error).overallLabel, 'Environment error');
    });

    test('running server reports the environment online', () {
      final ServiceAggregate aggregate = build(web: ServiceState.running);
      expect(aggregate.overallState, ServiceState.running);
      expect(aggregate.overallLabel, 'Environment online');
      expect(aggregate.allRunning, isTrue);
    });

    test('stopped server keeps the environment offline', () {
      expect(build().overallLabel, 'Environment offline');
    });
  });
}
