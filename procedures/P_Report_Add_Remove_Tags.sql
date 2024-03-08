--liquibase formatted sql

--changeset NicolasGriesdorn:03445a46 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             :
--      Author : Jacob Lowe
--             :
--     Created : 2019-12-12
--             :
--  NG20201001 : Added case logic for tags
--  NG20240226 : Added Admin Add logic to allow certain users access to restricted tags
-- =============================================
ALTER PROCEDURE [Report].[P_Report_Add_Remove_Tags]
    (
        @Account VARCHAR(MAX),
        @Tag VARCHAR(MAX),
        @Action SMALLINT, --0 show, 1 Insert, 2 Remove
        @SessionAccountID INT,
        @UserID INT

    )
AS

BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF ISNULL(@SessionAccountID, 0) <> 2 --Restrict to Account 2
        BEGIN
            SELECT 'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
            RETURN;
        END;

    IF (ISNULL(@Account, '') = '')
        BEGIN
            SELECT 'Must enter Account IDs' AS [Error Message];
            RETURN;
        END;

    IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfAccounts;
        END;

    CREATE TABLE #ListOfAccounts
    (
        AccountID INT
    );
    INSERT INTO #ListOfAccounts
    (
        AccountID
    )
    SELECT ID
    FROM dbo.fnSplitter(@Account);

    IF
        EXISTS
        (
            SELECT 1
            FROM #ListOfAccounts AS la
            WHERE
                NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.Account AS a
                    WHERE a.Account_ID = la.AccountID
                )
        )
        BEGIN
            SELECT 'Invalid Account Entered' AS [Error Message];
            RETURN;
        END;

    IF (@Action = 1)
        BEGIN
            IF @Tag = 'ProgramExclusive'
                RAISERROR (
                    'The following Tag is a restricted use tag and can only be added by Admin level users, please use the Admin Add function if you have authorization and try again.', -- noqa: LT05
                    14,
                    1
                );

            INSERT INTO Account.tblTags
            (
                SubjectId,
                SubjectTypeId,
                Tag
            )
            SELECT
                la.AccountID,
                1 AS [SubjectTypeId],
                @Tag AS [Tag]
            FROM #ListOfAccounts AS la
            WHERE
                NOT EXISTS
                (
                    SELECT *
                    FROM Account.tblTags AS t
                    WHERE
                        t.SubjectId = la.AccountID -- noqa: RF03
                        AND t.SubjectTypeId = 1
                        AND t.Tag = @Tag

                );
        END;

    IF (@Action = 2) --NG20240307
        BEGIN

            IF @UserID NOT IN (279685, 259617, 145761)
                RAISERROR (
                    'This user is not authorized to use this feature, please contact the Product Development team if you need to add this tag.', 14, 1
                );



            INSERT INTO Account.tblTags
            (
                SubjectId,
                SubjectTypeId,
                Tag
            )
            SELECT
                la.AccountID,
                1 AS [SubjectTypeId],
                @Tag AS [Tag]
            FROM #ListOfAccounts AS la
            WHERE
                NOT EXISTS
                (
                    SELECT *
                    FROM Account.tblTags AS t
                    WHERE
                        t.SubjectId = la.AccountID -- noqa: RF03
                        AND t.SubjectTypeId = 1
                        AND t.Tag = @Tag
                );
        END; --NG20240307

    IF (@Action = 3)
        BEGIN

            IF
                EXISTS (
                    SELECT *
                    FROM MarketPlace.tblAccountBrandedMPTier AS abt
                    WHERE abt.AccountID = @Account AND abt.BrandedMPID = 10 AND abt.BrandedMPTierID = 61 AND abt.Status = 1 -- noqa: RF03
                )
                RAISERROR (
                    'This account is currently configured as TBV, the tag cannot be removed until the account is no longer marked as TBV.', 15, 1
                );


            DELETE t
            FROM #ListOfAccounts AS la
            JOIN Account.tblTags AS t
                ON
                    t.SubjectId = la.AccountID
                    AND t.SubjectTypeId = 1
                    AND t.Tag = @Tag;

        END;

    SELECT
        la.AccountID,
        CASE
            WHEN ISNULL(t.Tag, 'N/A') = 'vzwaccounttransfer' THEN 'VZW Account Transfer'
            WHEN ISNULL(t.Tag, 'N/A') = 'xfinityterms' THEN 'XFinity Terms'
            ELSE ISNULL(t.Tag, 'N/A')
        END AS [Tag]												--NG20201001
    FROM #ListOfAccounts AS la
    LEFT JOIN Account.tblTags AS t
        ON
            t.SubjectId = la.AccountID
            AND t.SubjectTypeId = 1;

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
    RETURN;
END CATCH;
