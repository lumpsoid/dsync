import 'package:flutter/material.dart';

import '../../paired_device_row.dart';
import '../../row_action.dart';

/// What a device row's run button says, in the user's words — here so the
/// button and the row's menu say it the same way.
const deviceRunSetupLabel = 'Set up run';

/// A device row's actions, in menu order ([RowAction] states the rule):
/// the row's run button ([onRunSetup]), and a copy of the address the row
/// shows — what gets typed on the other device, or into `dsync pair`.
///
/// The row's tap (the device's page) is the row itself and is not
/// repeated, and nothing destructive is offered: revoking lives on the
/// device's page behind its confirmation, one deliberate step away from a
/// dense list, and a menu here would bring it back one mis-click from "Set
/// up run".
List<RowAction> deviceRowActions(
  PairedDeviceRow row, {
  required VoidCallback onRunSetup,
}) => [
  RowCommand(
    label: deviceRunSetupLabel,
    icon: Icons.sync,
    destructive: false,
    shortcut: null,
    onSelected: onRunSetup,
  ),
  RowCopy(value: row.address, what: 'address'),
];
