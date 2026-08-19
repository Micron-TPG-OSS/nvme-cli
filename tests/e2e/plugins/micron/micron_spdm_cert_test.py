# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron vs-spdm-cert command.

The vs-spdm-cert command runs the SPDM requester handshake in band over NVMe
Security Send/Receive, retrieves the certificate chain from a certificate slot,
and reports whether the device presents a self-signed certificate or a full
chain terminating at a self-signed root CA.  It also hashes the retrieved chain
and compares it against the GET_DIGESTS value for the slot.

SPDM is a firmware capability rather than a model one, so most drives will not
support it; every test that needs a real chain probes first and skips when the
handshake cannot complete.

Tests in this module verify:
  * Error handling for a non-existent device, an out-of-range slot, an
    out-of-range --secp/--conn-id, and an invalid --output-format value --
    none of which need SPDM support, since the argument checks run first.
  * Text output by default and JSON with --output-format=json.
  * The JSON shape: the summary fields, and a "certificates" array whose length
    matches certificate_count.
  * That the classification is one of the three known values and is consistent
    with the self_signed flags of the chain.
  * That the digest and root-hash checks pass on a supported drive.
  * That --output-file writes a DER blob whose first certificate openssl can
    parse.
  * Consistency of the reported values between JSON and text output.
"""

import json
import os
import re
import shutil
import subprocess

from .micron_test import TestMicron

_CLASSIFICATIONS = {"self-signed", "full chain", "incomplete chain"}

# Substrings that mark a drive or firmware without a reachable SPDM responder,
# as opposed to a genuine failure of the command.  A drive whose firmware has no
# SPDM responder rejects the security protocol outright, which surfaces as
# Invalid Field in Command or as ENOTSUP from a host driver that screens the
# protocol, so both spellings appear here.
_UNSUPPORTED_MARKERS = (
    "does not support Security Send/Receive",
    "may have no SPDM responder",
    "Invalid Field in Command",
    "not supported",
    "UnsupportedRequest",
    "device offers no supported version",
    "is not populated",
)

_SUMMARY_KEYS = {
    "slot",
    "spdm_version",
    "hash_algorithm",
    "certificate_count",
    "classification",
    "classification_detail",
    "digest_check",
    "root_hash_check",
    "micron_origin",
    "root_hash",
    "certificates",
}


class TestMicronVsSpdmCert(TestMicron):
    """Test suite for the micron vs-spdm-cert plugin command."""

    # Cached result of the SPDM availability probe.  None means "not yet
    # probed"; the handshake is several round trips, so it is run once.
    _spdm_available = None

    def _run_spdm_cert(self, device=None, args=""):
        """Run vs-spdm-cert and return the CompletedProcess result."""
        return self.run_plugin_cmd("vs-spdm-cert", device=device, args=args)

    def _is_spdm_available(self):
        """Return True if the drive answers the SPDM handshake."""
        cls = type(self)
        if cls._spdm_available is None:
            result = self._run_spdm_cert()
            cls._spdm_available = (result.returncode == 0
                                   or not self._is_unsupported(result))
            cls._spdm_probe_output = self._diagnostics(result)
        return cls._spdm_available

    @staticmethod
    def _diagnostics(result):
        """Return the streams a diagnostic may have landed on.

        Text mode reports errors on stderr, but JSON mode emits an {"error":...}
        object on stdout, so both have to be inspected.
        """
        return f"{result.stderr}\n{result.stdout}"

    @classmethod
    def _is_unsupported(cls, result):
        """Return True if result shows the drive has no SPDM responder."""
        output = cls._diagnostics(result)
        return any(marker in output for marker in _UNSUPPORTED_MARKERS)

    def _skip_if_unavailable(self):
        """Skip the calling test if the drive has no SPDM responder."""
        if not self._is_spdm_available():
            self.skipTest(
                f"vs-spdm-cert reports no SPDM support on this drive "
                f"({type(self)._spdm_probe_output.strip()!r})"
            )

    def _spdm_cert_json(self, args="--output-format=json"):
        """Run vs-spdm-cert in JSON mode and return the parsed object."""
        self._skip_if_unavailable()
        result = self.run_plugin_cmd_check("vs-spdm-cert", args=args)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            self.fail(f"stdout is not valid JSON: {exc}\nstdout={result.stdout!r}")

    def test_bad_device_returns_error(self):
        """vs-spdm-cert fails when the device does not exist.

        Only the device name prefix is asserted, because the OS strerror text
        appended to it differs between Windows and Linux.
        """
        device = "/dev/nvme-nonexistent-test-device"
        result = self._run_spdm_cert(device=device)

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for a non-existent device",
        )
        self.assertIn(
            device, result.stderr,
            f"Expected {device!r} in stderr, got: {result.stderr!r}",
        )

    def test_invalid_slot_returns_error(self):
        """vs-spdm-cert rejects a slot above the SPDM maximum of 7.

        The range check runs before any device I/O, so this holds regardless of
        whether the drive supports SPDM.
        """
        result = self._run_spdm_cert(args="--slot=8")

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for --slot=8",
        )
        self.assertIn(
            "Invalid slot", result.stderr,
            f"Expected 'Invalid slot' in stderr, got: {result.stderr!r}",
        )

    def test_out_of_range_secp_returns_error(self):
        """vs-spdm-cert rejects a --secp value that does not fit in a byte."""
        result = self._run_spdm_cert(args="--secp=256")

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for --secp=256",
        )
        self.assertIn(
            "must each fit in one byte", result.stderr,
            f"Expected a one-byte range message in stderr, got: {result.stderr!r}",
        )

    def test_out_of_range_conn_id_returns_error(self):
        """vs-spdm-cert rejects a --conn-id value that does not fit in a byte."""
        result = self._run_spdm_cert(args="--conn-id=256")

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for --conn-id=256",
        )
        self.assertIn(
            "must each fit in one byte", result.stderr,
            f"Expected a one-byte range message in stderr, got: {result.stderr!r}",
        )

    def test_invalid_output_format_returns_error(self):
        """vs-spdm-cert fails for an unrecognised --output-format value.

        Format validation runs before the slot range check and before any
        device I/O, so no SPDM support is needed.
        """
        result = self._run_spdm_cert(args="--output-format=notaformat")

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for an invalid --output-format value",
        )
        self.assertIn(
            "Invalid output format", result.stderr,
            f"Expected 'Invalid output format' in stderr, got: {result.stderr!r}",
        )

    def test_default_output_is_text(self):
        """vs-spdm-cert produces human-readable text by default."""
        self._skip_if_unavailable()
        result = self.run_plugin_cmd_check("vs-spdm-cert")

        self.assertRegex(
            result.stdout, r"Certificate count\s*:\s*\d+",
            f"Expected a 'Certificate count:' line in text output, "
            f"got: {result.stdout!r}",
        )
        with self.assertRaises((json.JSONDecodeError, ValueError),
                               msg="Default output must not be JSON"):
            json.loads(result.stdout)

    def test_output_format_json_produces_valid_json(self):
        """vs-spdm-cert produces valid JSON when --output-format=json is passed."""
        data = self._spdm_cert_json()
        self.assertIsInstance(data, dict)

    def test_json_has_expected_keys(self):
        """The JSON object contains exactly the documented summary keys.

        An unexpected key means a field was added without updating this test.
        """
        data = self._spdm_cert_json()

        missing = _SUMMARY_KEYS - set(data.keys())
        extra = set(data.keys()) - _SUMMARY_KEYS
        self.assertFalse(missing, f"Missing keys in vs-spdm-cert JSON: {missing}")
        self.assertFalse(extra, f"Unexpected keys in vs-spdm-cert JSON: {extra}")

    def test_certificate_count_matches_array_length(self):
        """certificate_count equals the length of the certificates array.

        At least one certificate must be present; a slot with none would have
        failed the command outright.
        """
        data = self._spdm_cert_json()
        certs = data["certificates"]

        self.assertIsInstance(certs, list, "'certificates' must be a JSON array")
        self.assertGreaterEqual(
            data["certificate_count"], 1,
            "Expected at least one certificate in the chain",
        )
        self.assertEqual(
            data["certificate_count"], len(certs),
            f"certificate_count ({data['certificate_count']}) does not match "
            f"the certificates array length ({len(certs)})",
        )

    def test_classification_is_known_and_consistent(self):
        """The classification is a known value and matches the chain shape.

        A single self-signed certificate is "self-signed"; a longer chain whose
        first certificate is self-signed is a "full chain"; anything else is
        "incomplete chain".
        """
        data = self._spdm_cert_json()
        certs = data["certificates"]
        classification = data["classification"]

        self.assertIn(
            classification, _CLASSIFICATIONS,
            f"Expected classification in {_CLASSIFICATIONS}, "
            f"got: {classification!r}",
        )

        if len(certs) == 1:
            expected = "self-signed" if certs[0]["self_signed"] else "incomplete chain"
        elif certs[0]["self_signed"]:
            expected = "full chain"
        else:
            expected = "incomplete chain"

        self.assertEqual(
            classification, expected,
            f"classification {classification!r} disagrees with the chain: "
            f"{len(certs)} certificates, first self_signed="
            f"{certs[0]['self_signed']}",
        )

    def test_digest_checks_pass(self):
        """Both integrity checks pass on a drive with a reachable SPDM chain.

        A failure here means the chain that was read is not the one the device
        attested to via GET_DIGESTS, which the command also treats as fatal.
        """
        data = self._spdm_cert_json()

        self.assertTrue(
            data["digest_check"],
            "The chain digest does not match the GET_DIGESTS value for the slot",
        )
        self.assertTrue(
            data["root_hash_check"],
            "The chain header RootHash does not match the root certificate",
        )

    def test_hash_algorithm_is_a_negotiated_sha2(self):
        """The negotiated hash algorithm is one of the three SHA-2 sizes offered."""
        data = self._spdm_cert_json()

        self.assertIn(
            data["hash_algorithm"], {"SHA-256", "SHA-384", "SHA-512"},
            f"Unexpected negotiated hash algorithm: {data['hash_algorithm']!r}",
        )

    def test_spdm_version_is_1_1_or_later(self):
        """The negotiated SPDM version is reported as 'major.minor', 1.1 or later."""
        data = self._spdm_cert_json()
        version = data["spdm_version"]

        m = re.fullmatch(r"(\d+)\.(\d+)", version)
        self.assertIsNotNone(
            m, f"Expected an SPDM version as '<major>.<minor>', got: {version!r}"
        )
        self.assertGreaterEqual(
            (int(m.group(1)), int(m.group(2))), (1, 1),
            f"Expected SPDM 1.1 or later, got: {version!r}",
        )

    def test_certificate_fields_are_populated(self):
        """Every certificate reports a subject, an issuer and a self_signed flag.

        The remaining fields are optional, because a certificate may legitimately
        omit them.
        """
        data = self._spdm_cert_json()

        for i, cert in enumerate(data["certificates"]):
            self.assertTrue(
                cert.get("subject"), f"Certificate {i} has no subject: {cert!r}"
            )
            self.assertTrue(
                cert.get("issuer"), f"Certificate {i} has no issuer: {cert!r}"
            )
            self.assertIsInstance(
                cert.get("self_signed"), bool,
                f"Certificate {i} has a non-boolean self_signed: {cert!r}",
            )
            self.assertEqual(
                cert.get("index"), i,
                f"Certificate at position {i} reports index {cert.get('index')!r}",
            )

    def test_output_file_holds_a_parsable_certificate(self):
        """--output-file writes the chain, and openssl can parse the leading cert.

        The file starts with the DSP0274 chain header, so the certificates begin
        after it; the header is skipped by locating the first DER SEQUENCE that
        openssl accepts.  Skipped when openssl is not installed.
        """
        openssl = shutil.which("openssl")
        if not openssl:
            self.skipTest("openssl is not available to validate the DER output")

        self._skip_if_unavailable()
        path = os.path.join(self.test_log_dir, "spdm-chain.der")
        result = self.run_plugin_cmd_check(
            "vs-spdm-cert", args=f"--output-file={path}"
        )
        self.assertEqual(result.returncode, 0)

        self.assertTrue(os.path.exists(path), f"{path} was not created")
        with open(path, "rb") as f:
            blob = f.read()
        self.assertGreater(len(blob), 4, f"{path} is too short to hold a chain")

        # The chain header is 4 bytes plus one hash; rather than recompute its
        # length, try each plausible offset until openssl parses a certificate.
        parsed = False
        for offset in (4 + size for size in (32, 48, 64)):
            if offset >= len(blob):
                continue
            proc = subprocess.run(
                [openssl, "x509", "-inform", "DER", "-noout", "-subject"],
                input=blob[offset:],
                capture_output=True,
            )
            if proc.returncode == 0:
                parsed = True
                break

        self.assertTrue(
            parsed,
            f"openssl could not parse a certificate out of {path} "
            f"({len(blob)} bytes)",
        )

    def test_json_and_text_agree(self):
        """The JSON and text output report the same values.

        Both formats are driven by the same data, so the summary values must
        match regardless of format.
        """
        data = self._spdm_cert_json()
        result = self.run_plugin_cmd_check("vs-spdm-cert")
        stdout = result.stdout

        count = re.search(r"Certificate count\s*:\s*(\d+)", stdout)
        self.assertIsNotNone(
            count, f"Could not parse the certificate count from: {stdout!r}"
        )
        self.assertEqual(
            data["certificate_count"], int(count.group(1)),
            "certificate_count differs between JSON and text output",
        )

        algo = re.search(r"Negotiated hash algorithm\s*:\s*(\S+)", stdout)
        self.assertIsNotNone(
            algo, f"Could not parse the hash algorithm from: {stdout!r}"
        )
        self.assertEqual(
            data["hash_algorithm"], algo.group(1),
            "hash_algorithm differs between JSON and text output",
        )

        self.assertIn(
            data["classification"], stdout,
            f"Text output does not report the classification "
            f"{data['classification']!r}",
        )

    def test_namespace_device_agrees_with_ctrl(self):
        """The namespace path yields the same chain as the controller path.

        A namespace path resolves to its parent controller, so the reported
        chain must be identical.
        """
        ns_probe = self._run_spdm_cert(device=self.ns1)
        if ns_probe.returncode != 0 and self._is_unsupported(ns_probe):
            self.skipTest(
                f"vs-spdm-cert reports no SPDM support via the namespace path "
                f"({self._diagnostics(ns_probe).strip()!r})"
            )

        result_ctrl = self.run_plugin_cmd_check(
            "vs-spdm-cert", device=self.ctrl, args="--output-format=json"
        )
        result_ns = self.run_plugin_cmd_check(
            "vs-spdm-cert", device=self.ns1, args="--output-format=json"
        )

        try:
            data_ctrl = json.loads(result_ctrl.stdout)
            data_ns = json.loads(result_ns.stdout)
        except json.JSONDecodeError as exc:
            self.fail(f"Output is not valid JSON: {exc}")

        self.assertEqual(
            data_ctrl["certificates"], data_ns["certificates"],
            f"Controller ({self.ctrl}) and namespace ({self.ns1}) paths "
            f"reported different certificate chains",
        )
