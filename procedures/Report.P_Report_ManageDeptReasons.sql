--liquibase formatted sql

--changeset JohnRose:637B8141-0447-41E7-BDD6-8F94E1116F0A stripComments:false runOnChange:true splitStatements:false
/*=============================================
       Author : Karina Masih-Hudson
  Create Date : 2024-05-20
  Description : CRM - Allows team leads to update, add, remove, view existing departments and ticket reasons so reason codes
				can be added when needed
				List|0|
				Add|1|
				Remove|2|
        Usage : EXEC [Report].[P_Report_ManageDeptReasons]
 =============================================*/
CREATE OR ALTER PROCEDURE [Report].[P_Report_ManageDeptReasons]
    (
        @Department VARCHAR(50), @Reason VARCHAR(100), @Option INT, @SessionID INT
    )
AS

BEGIN TRY
    BEGIN
        --DECLARE
        --    @Department VARCHAR(50) = 'Customer Service'
        --    , @Reason VARCHAR(100) = 'Pin Return'
        --    , @Option INT = 0 --List|0|Add|1|Remove|2|
        --    , @SessionID INT = 2

        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        IF (@SessionID <> 2)
            BEGIN
                SELECT 'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
                RETURN;
            END;

        IF
            (@Option <> 0 AND (ISNULL(@Department, '') = '' AND ISNULL(@Reason, '') = ''))
            BEGIN
                SELECT 'Department and/or reason cannot be blank if adding or removing.' AS [Error Message]
                RETURN;
            END;

        IF
            (@Option <> 0 AND (ISNULL(@Department, '') = '' AND ISNULL(@Reason, '') <> ''))
            BEGIN
                SELECT 'Department cannot be blank if adding or removing reason.' AS [Error Message]
                RETURN;
            END;


        IF (
            @Option = 1 AND (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') LIKE '')
            AND EXISTS (
                SELECT TOP 1 1
                FROM Cellday_Prod.dbo.CRM_Department AS cd
                WHERE
                    cd.Name = @Department
                    AND cd.Status = 1
            )
        )
            BEGIN
                SELECT 'Similar department name already exists. Please review.' AS [Error Message]
                RETURN;
            END;

        IF (
            @Option = 1 AND (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') NOT LIKE '')
            AND EXISTS (
                SELECT TOP 1 1
                FROM Cellday_Prod.dbo.CRM_Department AS cd
                JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                    ON cr.Category = cd.ID
                WHERE
                    cd.Name = @Department
                    AND cr.Name LIKE '%' + @Reason + '%'
                    AND cr.Status = 1
            )
        )
            BEGIN
                SELECT 'Similar reason under department name already exists. Please review.' AS [Error Message]
                RETURN;
            END;

        IF (@Option = 1)  --Add
            BEGIN

                IF (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') NOT LIKE '')
                    BEGIN
                        IF
                            NOT EXISTS (
                                SELECT 1
                                FROM dbo.CRM_Department
                                WHERE Name = @Department
                            )
                            BEGIN
                                INSERT INTO Cellday_Prod.dbo.CRM_Department
                                (ID, Name, Status, DepartmentImage)
                                SELECT
                                    MAX(cd.ID) + 1 AS ID
                                    , @Department AS [Name]
                                    , 1 AS [Status]
                                    , NULL AS DepartmentImage
                                FROM Cellday_Prod.dbo.CRM_Department AS cd
                            END
                        ELSE
                            BEGIN
                                UPDATE cd
                                SET cd.Status = 1
                                --SELECT *
                                FROM dbo.CRM_Department AS cd
                                WHERE
                                    cd.Name = @Department
                                    AND cd.Status = 0
                            END

                        IF
                            NOT EXISTS (
                                SELECT 1
                                FROM Cellday_Prod.dbo.CRM_Department AS cd
                                JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                                    ON cr.Category = cd.ID
                                WHERE
                                    cr.Name = @Reason
                                    AND cr.[Cat_Desc] = @Department
                            )
                            BEGIN
                                INSERT INTO Cellday_Prod.dbo.CRM_Reason
                                (Category, Name, Cat_desc, Status)
                                SELECT
                                    cd.ID AS [Category]
                                    , @Reason AS [Name]
                                    , cd.Name AS [Cat_Desc]
                                    , 1 AS [Status]
                                FROM Cellday_Prod.dbo.CRM_Department AS cd
                                WHERE
                                    cd.Name = @Department
                            END
                        ELSE
                            BEGIN
                                UPDATE cr
                                SET cr.Status = 1
                                --SELECT *
                                FROM Cellday_Prod.dbo.CRM_Department AS cd
                                JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                                    ON cr.Category = cd.ID
                                WHERE
                                    cr.Name = @Reason
                                    AND cr.Status = 0
                            END
                    END;
                IF (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') LIKE '')
                    BEGIN
                        IF
                            NOT EXISTS (
                                SELECT 1
                                FROM dbo.CRM_Department
                                WHERE Name = @Department
                            )
                            BEGIN
                                INSERT INTO Cellday_Prod.dbo.CRM_Department
                                (ID, Name, Status, DepartmentImage)
                                SELECT
                                    MAX(cd.ID) + 1 AS ID
                                    , @Department AS [Name]
                                    , 1 AS [Status]
                                    , NULL AS DepartmentImage
                                FROM Cellday_Prod.dbo.CRM_Department AS cd
                            END
                        ELSE
                            BEGIN
                                UPDATE cd
                                SET cd.Status = 1
                                --SELECT *
                                FROM dbo.CRM_Department AS cd
                                WHERE
                                    cd.Name = @Department
                                    AND cd.Status = 0
                            END
                    END;

                SELECT
                    cd.Name AS [DepartmentName]
                    , cd.Status AS [DepartmentStatus]
                    , cr.Name AS [Reason]
                    , cr.Status AS [ReasonStatus]
                FROM dbo.CRM_Department AS cd
                LEFT JOIN dbo.CRM_Reason AS cr
                    ON
                        cr.Category = cd.ID
                        AND cr.Name = @Reason
                        AND cd.Status = 1
                        AND cr.Status = 1
                WHERE
                    cd.Name = @Department
            END;

        IF (@Option = 2)  --Remove
            BEGIN
                --turn off department if no reason listed
                IF (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') LIKE '')
                    BEGIN
                        UPDATE cd
                        SET cd.Status = 0
                        --SELECT *
                        FROM Cellday_Prod.dbo.CRM_Department AS cd
                        WHERE cd.Name = @Department

                        UPDATE cr
                        SET cr.Status = 0
                        --SELECT *
                        FROM Cellday_Prod.dbo.CRM_Department AS cd
                        JOIN cellday_prod.dbo.CRM_Reason AS cr
                            ON cr.Category = cd.ID
                        WHERE cd.Name = @Department

                        SELECT
                            cd.Name AS [DepartmentName]
                            , cd.Status AS [DepartmentStatus]
                            , cr.Name AS [Reason]
                            , cr.Status AS [ReasonStatus]
                        FROM dbo.CRM_Department AS cd
                        LEFT JOIN dbo.CRM_Reason AS cr
                            ON
                                cr.Category = cd.ID
                                AND cr.Status = 0
                        WHERE
                            cd.Name = @Department
                    END;

                --turn off just reason if department and reason listed
                IF (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') NOT LIKE '')
                    BEGIN
                        UPDATE cr
                        SET cr.Status = 0
                        --SELECT *
                        FROM Cellday_Prod.dbo.CRM_Department AS cd
                        JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                            ON cr.Category = cd.ID
                        WHERE
                            cd.Name = @Department
                            AND cr.Name = @Reason

                        SELECT
                            cd.Name AS [DepartmentName]
                            , cd.Status AS [DepartmentStatus]
                            , cr.Name AS [Reason]
                            , cr.Status AS [ReasonStatus]
                        FROM dbo.CRM_Department AS cd
                        JOIN dbo.CRM_Reason AS cr
                            ON
                                cr.Category = cd.ID
                                AND cr.Name = @Reason
                                AND cr.Status = 0
                        WHERE
                            cd.Name = @Department
                    END;

            END;

        IF (@Option = 0)  --List
            BEGIN
                IF (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') NOT LIKE '')
                    BEGIN
                        SELECT
                            cd.Name AS [Department]
                            , cd.Status AS [DepartmentStatus]
                            , cr.Name AS [Reason]
                            , cr.Status AS [Reason Status]
                        FROM Cellday_Prod.dbo.CRM_Department AS cd
                        JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                            ON cr.Category = cd.ID
                        WHERE
                            cd.Name = @Department
                            AND cr.Name = @Reason
                        ORDER BY cd.Name
                    END;
                IF (ISNULL(@Department, '') NOT LIKE '' AND ISNULL(@Reason, '') LIKE '')
                    BEGIN
                        SELECT
                            cd.Name AS [Department]
                            , cd.Status AS [DepartmentStatus]
                            , cr.Name AS [Reason]
                            , cr.Status AS [Reason Status]
                        FROM Cellday_Prod.dbo.CRM_Department AS cd
                        LEFT JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                            ON cr.Category = cd.ID
                        WHERE
                            cd.Name = @Department
                        ORDER BY cd.Name
                    END;
                IF (ISNULL(@Department, '') LIKE '' AND ISNULL(@Reason, '') NOT LIKE '')
                    BEGIN
                        SELECT
                            cd.Name AS [Department]
                            , cd.Status AS [DepartmentStatus]
                            , cr.Name AS [Reason]
                            , cr.Status AS [Reason Status]
                        FROM Cellday_Prod.dbo.CRM_Reason AS cr
                        LEFT JOIN Cellday_Prod.dbo.CRM_Department AS cd
                            ON cr.Category = cd.ID
                        WHERE
                            cr.Name = @Reason
                        ORDER BY cd.Name
                    END;
                IF (ISNULL(@Department, '') LIKE '' AND ISNULL(@Reason, '') LIKE '')
                    BEGIN
                        SELECT
                            cd.Name AS [Department]
                            , cd.Status AS [DepartmentStatus]
                            , cr.Name AS [Reason]
                            , cr.Status AS [Reason Status]
                        FROM Cellday_Prod.dbo.CRM_Department AS cd
                        JOIN Cellday_Prod.dbo.CRM_Reason AS cr
                            ON cr.Category = cd.ID
                        ORDER BY cd.Name
                    END;
            END;

    END;

END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
