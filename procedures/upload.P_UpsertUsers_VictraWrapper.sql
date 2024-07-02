--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-19
-- Description: Victra wrapper temp solution until data upload v2 is completed.
-- =============================================
CREATE OR ALTER PROCEDURE [upload].[P_UpsertUsers_VictraWrapper]
    (
        @FileId INT
    )
AS
BEGIN

    DECLARE @TopParentAccountId INT = 158286;
    EXECUTE Upload.P_UpsertUsers @TopParentAccountId, @FileId;

END;
