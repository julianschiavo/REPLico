import unittest

from Benchmarks.compare import check_sequence_result


class SequenceResponseTests(unittest.TestCase):
    def test_empty_output_and_ordered_text_are_accepted(self):
        for values in [[""], ["first", "second"], ["é🙂\n\x00"]]:
            check_sequence_result(
                {"content": [{"type": "text", "text": text} for text in values]},
                {"didFail": False, "text": values}, "fixture", 0,
            )

    def test_failure_status_must_match_the_expected_outcome(self):
        response = {"content": [{"type": "text", "text": "caught"}], "isError": True}
        with self.assertRaises(RuntimeError):
            check_sequence_result(response, {"didFail": False, "text": ["caught"]}, "fixture", 0)
        check_sequence_result(response, {"didFail": True, "text": ["caught"]}, "fixture", 0)

    def test_missing_reordered_or_extra_output_is_rejected(self):
        expected = {"didFail": False, "text": ["first", "second"]}
        for values in [[], ["first"], ["second", "first"], ["first", "second", "extra"]]:
            with self.assertRaises(RuntimeError):
                check_sequence_result(
                    {"content": [{"type": "text", "text": text} for text in values]},
                    expected, "fixture", 2,
                )

    def test_nontext_items_cannot_bypass_the_expected_content(self):
        with self.assertRaises(RuntimeError):
            check_sequence_result(
                {"content": [{"type": "text", "text": "ok"}, {"type": "image", "data": ""}]},
                {"didFail": False, "text": ["ok"]}, "fixture", 0,
            )

    def test_ordered_images_validate_bytes_mime_and_digest(self):
        expected = {"didFail": False, "content": [
            {"type": "text", "text": "frame"},
            {"type": "image", "mimeType": "image/png", "byteCount": 5,
             "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"},
        ]}
        content = [{"type": "text", "text": "frame"},
                   {"type": "image", "mimeType": "image/png", "data": "aGVsbG8="}]
        check_sequence_result({"content": content}, expected, "fixture", 0)
        for image in [
            {**content[1], "mimeType": "image/jpeg"},
            {**content[1], "data": "aGVsbGE="},
            {**content[1], "data": "aA=="},
            {**content[1], "data": "not base64"},
        ]:
            with self.assertRaises(RuntimeError):
                check_sequence_result({"content": [content[0], image]}, expected, "fixture", 0)
        with self.assertRaises(RuntimeError):
            check_sequence_result({"content": list(reversed(content))}, expected, "fixture", 0)
