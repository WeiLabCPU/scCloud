"""多样本整合产物一键导入目标项目的单元测试。"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import HTTPException
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import get_settings
from app.convert.router import ConvertImportRequest, import_converted_to_project
from app.db import models
from app.projects.router import ProjectCreate, create_project, list_project_files
from app.utils.storage_paths import is_path_within, user_convert_dir


class TestConvertImportToProject(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.projects_root = os.path.join(self._tmpdir.name, "projects")
        os.makedirs(self.projects_root, exist_ok=True)
        self._env_patch = patch.dict(
            os.environ,
            {"PROJECTS_ROOT": self.projects_root},
            clear=False,
        )
        self._env_patch.start()
        get_settings.cache_clear()

        self.engine = create_engine(
            "sqlite://",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        models.Base.metadata.create_all(self.engine)
        self.TestSession = sessionmaker(
            bind=self.engine,
            autocommit=False,
            autoflush=False,
            expire_on_commit=False,
        )
        self._session_patch = patch.object(models, "SessionLocal", self.TestSession)
        self._session_patch.start()

    def tearDown(self) -> None:
        self._session_patch.stop()
        models.Base.metadata.drop_all(self.engine)
        self.engine.dispose()
        self._env_patch.stop()
        get_settings.cache_clear()
        self._tmpdir.cleanup()

    def _create_user(self, *, user_id: int, username: str, role: str = "super") -> models.User:
        db = self.TestSession()
        try:
            user = models.User(
                id=user_id,
                username=username,
                email=f"{username}@example.com",
                password_hash="not-a-real-hash",
                role=role,
                is_guest=False,
                is_active=True,
                max_projects=10,
                total_quota=100,
                used_quota=0,
            )
            db.add(user)
            db.commit()
            db.refresh(user)
            return user
        finally:
            db.close()

    def _write_merged_rds(
        self,
        user: models.User,
        payload: bytes = b"fake-rds-content",
        groups: dict[str, str] | None = None,
    ) -> str:
        cdir = Path(user_convert_dir(self.projects_root, user.id, user.username)) / "mtx_merge_abcd1234"
        cdir.mkdir(parents=True, exist_ok=True)
        rds_path = cdir / "merged.rds"
        rds_path.write_bytes(payload)
        if groups:
            (cdir / "merged.rds_groups.json").write_text(
                json.dumps(groups, ensure_ascii=False),
                encoding="utf-8",
            )
        return str(rds_path)

    async def test_import_merged_rds_and_groups_into_project_and_listed_in_project_files(self) -> None:
        user = self._create_user(user_id=10, username="alice")
        src_path = self._write_merged_rds(
            user,
            payload=b"merged-rds-binary",
            groups={"Sample1": "Ctrl", "Sample2": "Treat"},
        )

        db = self.TestSession()
        try:
            proj = await create_project(
                ProjectCreate(name="PBMC_Merged", species="human"),
                current_user=user,
                db=db,
            )

            resp = await import_converted_to_project(
                ConvertImportRequest(
                    source_path=src_path,
                    project_id=proj.id,
                    filename="merged_samples.rds",
                ),
                current_user=user,
                db=db,
            )

            self.assertEqual(resp.status, "imported")
            self.assertEqual(resp.project_id, proj.id)
            self.assertEqual(resp.filename, "merged_samples.rds")
            self.assertEqual(resp.sample_groups, {"Sample1": "Ctrl", "Sample2": "Treat"})
            self.assertTrue(
                is_path_within(resp.path, os.path.join(proj.storage_path, "_uploaded")),
                resp.path,
            )
            self.assertEqual(Path(resp.path).read_bytes(), b"merged-rds-binary")

            # _groups.json 伴生文件也已复制并独立存储
            groups_sidecar = Path(resp.path + "_groups.json")
            self.assertTrue(groups_sidecar.is_file())
            self.assertEqual(
                json.loads(groups_sidecar.read_text(encoding="utf-8")),
                {"Sample1": "Ctrl", "Sample2": "Treat"},
            )
            # 验证采用副本而非硬链接（避免 r-engine uid=1000 与 backend uid=10001 跨 UID EPERM）
            self.assertNotEqual(os.stat(src_path).st_ino, os.stat(resp.path).st_ino)

            # list_project_files 可以看到去除了 UUID 前缀的文件名
            listed = await list_project_files(proj.id, current_user=user, db=db)
            self.assertEqual([f.filename for f in listed.files], ["merged_samples.rds"])
            self.assertEqual(listed.files[0].path, resp.path)

            # 配额递增且再次导入同名文件会自动覆盖旧副本
            resp2 = await import_converted_to_project(
                ConvertImportRequest(
                    source_path=src_path,
                    project_id=proj.id,
                    filename="merged_samples.rds",
                ),
                current_user=user,
                db=db,
            )
            self.assertFalse(os.path.exists(resp.path))
            self.assertFalse(os.path.exists(resp.path + "_groups.json"))
            self.assertTrue(os.path.isfile(resp2.path))
            listed2 = await list_project_files(proj.id, current_user=user, db=db)
            self.assertEqual([f.filename for f in listed2.files], ["merged_samples.rds"])

            refreshed_user = db.query(models.User).filter(models.User.id == user.id).first()
            self.assertEqual(refreshed_user.used_quota, 2)
        finally:
            db.close()

    async def test_import_rejects_other_users_source_or_project(self) -> None:
        alice = self._create_user(user_id=1, username="alice")
        bob = self._create_user(user_id=2, username="bob")
        alice_rds = self._write_merged_rds(alice)

        db = self.TestSession()
        try:
            alice_proj = await create_project(
                ProjectCreate(name="AliceProj", species="human"),
                current_user=alice,
                db=db,
            )
            bob_proj = await create_project(
                ProjectCreate(name="BobProj", species="mouse"),
                current_user=bob,
                db=db,
            )

            # Bob 不能导入 Alice 的转换产物
            with self.assertRaises(HTTPException) as ctx1:
                await import_converted_to_project(
                    ConvertImportRequest(source_path=alice_rds, project_id=bob_proj.id),
                    current_user=bob,
                    db=db,
                )
            self.assertEqual(ctx1.exception.status_code, 403)

            # Alice 不能导入到 Bob 的项目
            with self.assertRaises(HTTPException) as ctx2:
                await import_converted_to_project(
                    ConvertImportRequest(source_path=alice_rds, project_id=bob_proj.id),
                    current_user=alice,
                    db=db,
                )
            self.assertEqual(ctx2.exception.status_code, 404)

            # 非法目标文件名被拦截
            with self.assertRaises(HTTPException) as ctx3:
                await import_converted_to_project(
                    ConvertImportRequest(
                        source_path=alice_rds,
                        project_id=alice_proj.id,
                        filename="../evil.rds",
                    ),
                    current_user=alice,
                    db=db,
                )
            self.assertEqual(ctx3.exception.status_code, 400)
        finally:
            db.close()

    async def test_import_rejects_analyzed_project(self) -> None:
        alice = self._create_user(user_id=1, username="alice")
        alice_rds = self._write_merged_rds(alice)

        db = self.TestSession()
        try:
            proj = await create_project(
                ProjectCreate(name="AnalyzedProj", species="human"),
                current_user=alice,
                db=db,
            )
            proj.has_analyzed = True
            db.commit()

            with self.assertRaises(HTTPException) as ctx:
                await import_converted_to_project(
                    ConvertImportRequest(source_path=alice_rds, project_id=proj.id),
                    current_user=alice,
                    db=db,
                )
            self.assertEqual(ctx.exception.status_code, 403)
        finally:
            db.close()
