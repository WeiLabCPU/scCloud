"""目录公开访问、下载鉴权及路径边界回归测试。"""
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.auth.deps import get_current_user
from app.datasets import router as datasets


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(datasets, "_data_root", lambda: tmp_path / "datasets")
    app = FastAPI()
    app.include_router(datasets.router)
    with TestClient(app) as client:
        yield client


def login(client, *, guest=False):
    client.app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(is_guest=guest)


def test_catalog_public_and_unknown_dataset(client):
    response = client.get("/api/datasets")
    assert response.status_code == 200
    assert response.json()["total"] == len(response.json()["datasets"])
    assert client.get("/api/datasets/pbmc3k").status_code == 200
    assert client.get("/api/datasets/unknown").status_code == 404


def test_download_requires_registered_user(client, tmp_path):
    url = "/api/datasets/pbmc3k/files/README.md"
    assert client.get(url).status_code == 401
    login(client, guest=True)
    assert client.get(url).status_code == 403
    login(client)
    assert client.get(url).status_code == 404
    directory = tmp_path / "datasets" / "pbmc3k"
    directory.mkdir(parents=True)
    (directory / "README.md").write_text("PBMC sample")
    response = client.get(url)
    assert response.status_code == 200
    assert response.text == "PBMC sample"
    assert "README.md" in response.headers["content-disposition"]
    assert client.get("/api/datasets/pbmc3k/files/private.txt").status_code == 404
    assert client.get("/api/datasets/bcell/files/README.md").status_code == 400


def test_download_blocks_sibling_prefix_symlink(client, tmp_path):
    login(client)
    sibling = tmp_path / "datasets2"
    sibling.mkdir()
    secret = sibling / "secret.md"
    secret.write_text("private")
    directory = tmp_path / "datasets" / "pbmc3k"
    directory.mkdir(parents=True)
    (directory / "README.md").symlink_to(secret)
    assert client.get("/api/datasets/pbmc3k/files/README.md").status_code == 404


def test_scenic_references_ignore_partial_and_wrong_database(client, tmp_path):
    url = "/api/datasets/scenic/references"
    assert client.get(url).json() == {"references": []}
    directory = tmp_path / "cistarget"
    directory.mkdir()
    for filename in (
        "hg38__test.mc9nr.genes_vs_motifs.rankings.feather",
        "mm10__test.mc9nr.genes_vs_motifs.rankings.feather.part",
        "hg19__test.mc_v10_clust.genes_vs_motifs.rankings.feather",
    ):
        (directory / filename).write_bytes(b"test")
    (directory / "mm9__test.mc9nr.genes_vs_motifs.rankings.feather").touch()
    assert client.get(url).json() == {"references": ["hg38"]}


def test_bundled_catalog_files_exist():
    root = datasets._DEV_DATA_ROOT
    for ds in datasets._load_catalog()["datasets"]:
        if ds["mode"] == "local":
            for item in ds["files"]:
                assert (root / ds["id"] / item["name"]).is_file()
