from base64 import b64encode
from io import BytesIO
from unittest.mock import MagicMock

from PIL import Image
import pytest

from sweatcaster import instagram_photo
from sweatcaster.dto import ApiError


def test_selected_photo_is_staged_with_matching_tool_and_reference(monkeypatch):
    image = BytesIO()
    Image.new("RGB", (48, 60), "#43bcae").save(image, "JPEG")
    data = instagram_photo.decode_photo(b64encode(image.getvalue()).decode("ascii"))
    signed = "https://test.r2.cloudflarestorage.com/upload?signature=test"
    library = MagicMock()
    library.request.return_value = {"key": "file-key", "new_presigned_url": signed}
    session = MagicMock()
    client = session.return_value.__enter__.return_value
    client.put.return_value.__enter__.return_value.status_code = 200
    monkeypatch.setattr(instagram_photo.requests, "Session", session)

    file = instagram_photo.stage_photo(library, data)
    assert file == {"name": "instagram.jpg", "mimetype": "image/jpeg", "s3key": "file-key"}
    assert library.request.call_args.kwargs["payload"]["tool_slug"] == "INSTAGRAM_POST_IG_USER_MEDIA"
    assert client.put.call_args.args == (signed,)
    assert client.put.call_args.kwargs["headers"] == {"Content-Type": "image/jpeg"}
    assert client.put.call_args.kwargs["data"] == image.getvalue()
    assert client.put.call_args.kwargs["allow_redirects"] is False


@pytest.mark.parametrize("value", ["not a photo", b64encode(b"not a jpeg").decode(), "A" * 5_600_000])
def test_reject_invalid_local_photo(value):
    with pytest.raises(ApiError):
        instagram_photo.decode_photo(value)


def test_bad_upload_destination_does_not_receive_photo(monkeypatch):
    library = MagicMock()
    library.request.return_value = {"key": "file-key", "new_presigned_url": "https://127.0.0.1/other"}
    session = MagicMock()
    monkeypatch.setattr(instagram_photo.requests, "Session", session)
    with pytest.raises(ApiError):
        instagram_photo.stage_photo(library, b"test")
    session.assert_not_called()
