--liquibase formatted sql

--changeset BrandonStahl:4407d33e-cf25-4334-8567-0e6e430c4cc9 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--      Author : Brandon Stahl
--             :
-- Create Date : 2024-04-10
--             :
-- Description : Returns a list of detokenized Federal Tax Ids per account
--             :
-- =============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_Get_Account_FEIN]
    (
        @AccountIds VARCHAR(MAX),
        @sessionID INT,
        @MaxBatchSize INT
    )
AS
BEGIN
    BEGIN TRY

        SET NOCOUNT ON;
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        IF ISNULL(@sessionID, 0) <> 2
            BEGIN
                SELECT 'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
                RETURN
            END;

        IF OBJECT_ID('tempdb..#tmpAccts') IS NOT NULL
            BEGIN
                DROP TABLE #tmpAccts;
            END;

        CREATE TABLE #tmpAccts
        (
            AccountID INT
        );

        INSERT INTO #tmpAccts
        (
            AccountID
        )
        SELECT ID
        FROM dbo.fnSplitter(REPLACE(TRANSLATE(@AccountIDs, '	 ', '##'), '#', ''));

        IF ((SELECT COUNT(DISTINCT a.AccountId) FROM #tmpAccts AS a) > ISNULL(@MaxBatchSize, 0))
            BEGIN
                SELECT 'The number of accounts exceeds the max batch size of ' + CAST(@MaxBatchSize AS VARCHAR(100)) AS [Error Message];
                RETURN;
            END

        SELECT DISTINCT
            a.Account_Id,
            ISNULL(ISNULL(piim.Token, a.FederalTaxID), '') AS FedTaxID
        FROM dbo.Account AS a
        JOIN #tmpAccts AS ta ON ta.AccountID = a.Account_ID
        LEFT JOIN Security.tblPiiMapping AS piim ON CAST(piim.[PiiMappingId] AS NVARCHAR(10)) = a.FederalTaxID;
    END TRY
    BEGIN CATCH
        SELECT 'An error has occured!' AS [Error Message]
    END CATCH;
END;
