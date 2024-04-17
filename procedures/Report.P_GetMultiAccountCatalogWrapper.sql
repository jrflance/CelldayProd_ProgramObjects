--liquibase formatted sql

--changeset  BrandonStahl:2203b772-a0aa stripComments:false runOnChange:true splitStatements:false

--=============================================
--				:
--	Author		: Brandon Stahl
--				:
--	Created		: 2024-04-11
--				:
--	Description	: Wraps P_GetMultiAccountCatalog to allow a parameter of comma separated
--              : accounts for SSRS reporting
--				:
--	Test Data   : EXEC [Report].[P_GetMultiAccountCatalogWrapper] '13379'
--=============================================
CREATE OR ALTER PROCEDURE [Report].[P_GetMultiAccountCatalogWrapper]
    (
        @AccountIds VARCHAR(MAX)
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @AccountIdList dbo.IDS;

    INSERT INTO @AccountIdList
    (
        Id
    )
    SELECT ID
    FROM dbo.fnSplitter(REPLACE(TRANSLATE(@AccountIDs, '	 ', '##'), '#', ''));

    EXEC [Report].[P_GetMultiAccountCatalog] @AccountIdList;

END
